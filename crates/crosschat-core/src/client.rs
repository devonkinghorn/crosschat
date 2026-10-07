//! `CrosschatClient`: the only Matrix API the UI sees.
//!
//! Alpha implementation notes:
//! * Uses classic `/sync` (works on every homeserver). Moving the room list to
//!   matrix-sdk-ui's `RoomListService` (Simplified Sliding Sync) is the next
//!   step; the public API here is shaped so callers won't change.
//! * Session tokens are persisted to `<data_dir>/session.json` with 0600
//!   permissions. Moving them into the OS keychain is tracked in the roadmap.

use crate::model::{
    self, CoreEvent, Message, NetworkInfo, RoomSummary, UserResult, build_main_timeline,
    parse_bridge_state, parse_event, threads_supported_from_features,
};
use anyhow::{Context, Result, anyhow, bail};
use matrix_sdk::{
    Client, Room, RoomMemberships,
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    deserialized_responses::RawAnySyncOrStrippedState,
    room::{MessagesOptions, RelationsOptions, IncludeRelations},
    ruma::{
        EventId, OwnedEventId, RoomId, UInt, UserId,
        api::{Direction, client::room::create_room},
        events::{
            StateEventType,
            relation::{RelationType, Thread},
            room::message::{Relation, RoomMessageEventContent},
        },
    },
    store::RoomLoadSettings,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{sync::broadcast, task::JoinHandle};
use tracing::{info, warn};

#[derive(Serialize, Deserialize)]
struct StoredSession {
    homeserver: String,
    session: MatrixSession,
}

#[derive(Clone, Default)]
struct LastMessage {
    ts: i64,
    body: String,
}

/// Cheaply clonable handle to a logged-in Matrix account.
#[derive(Clone)]
pub struct CrosschatClient {
    client: Client,
    data_dir: PathBuf,
    events: broadcast::Sender<CoreEvent>,
    last: Arc<Mutex<HashMap<String, LastMessage>>>,
    sync_task: Arc<Mutex<Option<JoinHandle<()>>>>,
}

fn session_path(data_dir: &Path) -> PathBuf {
    data_dir.join("session.json")
}

fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    std::fs::write(path, contents)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

async fn build_client(homeserver: &str, data_dir: &Path) -> Result<Client> {
    std::fs::create_dir_all(data_dir)?;
    let builder = Client::builder().sqlite_store(data_dir.join("store"), None);
    let builder = if homeserver.starts_with("http://") || homeserver.starts_with("https://") {
        builder.homeserver_url(homeserver)
    } else {
        builder.server_name_or_homeserver_url(homeserver)
    };
    Ok(builder.build().await?)
}

fn raw_json<T>(raw: &matrix_sdk::ruma::serde::Raw<T>) -> Option<Value> {
    serde_json::from_str(raw.json().get()).ok()
}

impl CrosschatClient {
    fn wrap(client: Client, data_dir: PathBuf) -> Self {
        let (events, _) = broadcast::channel(512);
        Self {
            client,
            data_dir,
            events,
            last: Default::default(),
            sync_task: Default::default(),
        }
    }

    /// Password login. `homeserver` may be a URL or a server name (resolved
    /// via `.well-known`).
    pub async fn login(
        homeserver: &str,
        username: &str,
        password: &str,
        data_dir: impl Into<PathBuf>,
        device_name: &str,
    ) -> Result<Self> {
        let data_dir = data_dir.into();
        // A fresh login gets a fresh store; stale crypto state for another
        // device would otherwise poison the new session.
        let _ = std::fs::remove_dir_all(data_dir.join("store"));
        let client = build_client(homeserver, &data_dir).await?;
        client
            .matrix_auth()
            .login_username(username, password)
            .initial_device_display_name(device_name)
            .send()
            .await
            .context("login failed")?;
        let session = client.matrix_auth().session().ok_or_else(|| anyhow!("no session after login"))?;
        let stored = StoredSession { homeserver: client.homeserver().to_string(), session };
        write_private(&session_path(&data_dir), &serde_json::to_vec_pretty(&stored)?)?;
        info!(user = ?client.user_id(), "logged in");
        Ok(Self::wrap(client, data_dir))
    }

    /// Restore a previous session from `data_dir`, if any.
    pub async fn restore(data_dir: impl Into<PathBuf>) -> Result<Option<Self>> {
        let data_dir = data_dir.into();
        let path = session_path(&data_dir);
        if !path.exists() {
            return Ok(None);
        }
        let stored: StoredSession = serde_json::from_slice(&std::fs::read(&path)?)?;
        let client = build_client(&stored.homeserver, &data_dir).await?;
        client.matrix_auth().restore_session(stored.session, RoomLoadSettings::default()).await?;
        Ok(Some(Self::wrap(client, data_dir)))
    }

    pub fn user_id(&self) -> String {
        self.client.user_id().map(|u| u.to_string()).unwrap_or_default()
    }

    pub fn device_id(&self) -> String {
        self.client.device_id().map(|d| d.to_string()).unwrap_or_default()
    }

    pub fn homeserver(&self) -> String {
        self.client.homeserver().to_string()
    }

    /// The Matrix access token. Used by the app to authenticate to crosschatd,
    /// which validates it with `/account/whoami`.
    pub fn access_token(&self) -> Option<String> {
        self.client.access_token()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<CoreEvent> {
        self.events.subscribe()
    }

    fn record_sync(&self, response: &matrix_sdk::sync::SyncResponse) {
        let own = self.user_id();
        let mut changed = !response.rooms.joined.is_empty()
            || !response.rooms.invited.is_empty()
            || !response.rooms.left.is_empty();
        for (room_id, update) in &response.rooms.joined {
            for ev in &update.timeline.events {
                let Some(json) = raw_json(ev.raw()) else { continue };
                if let Some(msg) = parse_event(&json, &own) {
                    if msg.thread_root.is_none() {
                        self.last
                            .lock()
                            .unwrap()
                            .insert(room_id.to_string(), LastMessage { ts: msg.ts, body: msg.body.clone() });
                    }
                    let _ = self.events.send(CoreEvent::NewMessage { room_id: room_id.to_string(), message: msg });
                    changed = true;
                }
            }
        }
        if changed {
            let _ = self.events.send(CoreEvent::RoomsChanged);
        }
    }

    /// One sync round-trip. Useful for tests and for the initial load.
    pub async fn sync_once(&self) -> Result<()> {
        let settings = SyncSettings::default().timeout(Duration::from_secs(0));
        let response = self.client.sync_once(settings).await?;
        self.record_sync(&response);
        Ok(())
    }

    /// Start the background sync loop (idempotent).
    pub fn start_sync(&self) {
        let mut guard = self.sync_task.lock().unwrap();
        if guard.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        let this = self.clone();
        *guard = Some(tokio::spawn(async move {
            let _ = this.events.send(CoreEvent::SyncState { state: "syncing".into() });
            loop {
                let settings = SyncSettings::default().timeout(Duration::from_secs(30));
                match this.client.sync_once(settings).await {
                    Ok(response) => this.record_sync(&response),
                    Err(e) => {
                        warn!("sync error: {e}");
                        let _ = this.events.send(CoreEvent::SyncState { state: format!("error: {e}") });
                        tokio::time::sleep(Duration::from_secs(5)).await;
                        let _ = this.events.send(CoreEvent::SyncState { state: "syncing".into() });
                    }
                }
            }
        }));
    }

    pub fn stop_sync(&self) {
        if let Some(h) = self.sync_task.lock().unwrap().take() {
            h.abort();
        }
    }

    fn room(&self, room_id: &str) -> Result<Room> {
        let id = <&RoomId>::try_from(room_id).context("invalid room id")?;
        self.client.get_room(id).ok_or_else(|| anyhow!("unknown room {room_id}"))
    }

    async fn state_content(room: &Room, ty: &str) -> Option<Value> {
        let events = room.get_state_events(StateEventType::from(ty)).await.ok()?;
        events.iter().find_map(|e| match e {
            RawAnySyncOrStrippedState::Sync(raw) => raw_json(raw).and_then(|v| v.get("content").cloned()),
            RawAnySyncOrStrippedState::Stripped(raw) => raw_json(raw).and_then(|v| v.get("content").cloned()),
        })
    }

    async fn network_of(room: &Room) -> Option<NetworkInfo> {
        for ty in ["m.bridge", "uk.half-shot.bridge"] {
            if let Some(n) = Self::state_content(room, ty).await.as_ref().and_then(parse_bridge_state) {
                return Some(n);
            }
        }
        let members = room.members_no_sync(RoomMemberships::JOIN).await.ok()?;
        let ids: Vec<String> = members.iter().map(|m| m.user_id().to_string()).collect();
        model::guess_network_from_members(ids.iter().map(String::as_str))
    }

    /// Joined rooms, most recently active first.
    pub async fn rooms(&self) -> Result<Vec<RoomSummary>> {
        let mut out = Vec::new();
        for room in self.client.joined_rooms() {
            let room_id = room.room_id().to_string();
            let name = room
                .display_name()
                .await
                .map(|n| n.to_string())
                .unwrap_or_else(|_| room_id.clone());
            let counts = room.unread_notification_counts();
            let last = self.last.lock().unwrap().get(&room_id).cloned();
            let last_ts = last
                .as_ref()
                .map(|l| l.ts)
                .or_else(|| room.latest_event_timestamp().map(|t| i64::from(t.0)))
                .unwrap_or(0);
            let threads_supported = Self::state_content(&room, "com.beeper.room_features")
                .await
                .as_ref()
                .and_then(threads_supported_from_features);
            out.push(RoomSummary {
                name,
                topic: room.topic(),
                is_dm: room.is_direct().await.unwrap_or(false),
                unread: counts.notification_count,
                highlights: counts.highlight_count,
                last_ts,
                last_message: last.map(|l| l.body),
                network: Self::network_of(&room).await,
                threads_supported,
                room_id,
            });
        }
        out.sort_by(|a, b| b.last_ts.cmp(&a.last_ts).then_with(|| a.name.cmp(&b.name)));
        Ok(out)
    }

    async fn fill_sender_names(room: &Room, msgs: &mut [Message]) {
        let mut cache: HashMap<String, String> = HashMap::new();
        for m in msgs.iter_mut() {
            if let Some(n) = cache.get(&m.sender) {
                m.sender_name = n.clone();
                continue;
            }
            let name = match <&UserId>::try_from(m.sender.as_str()) {
                Ok(uid) => room
                    .get_member_no_sync(uid)
                    .await
                    .ok()
                    .flatten()
                    .and_then(|mem| mem.display_name().map(str::to_owned)),
                Err(_) => None,
            }
            .unwrap_or_else(|| m.sender.trim_start_matches('@').split(':').next().unwrap_or("").to_owned());
            cache.insert(m.sender.clone(), name.clone());
            m.sender_name = name;
        }
    }

    /// The channel timeline (thread replies folded into root summaries),
    /// oldest first. `limit` is the number of raw events fetched.
    pub async fn timeline(&self, room_id: &str, limit: u32) -> Result<Vec<Message>> {
        let room = self.room(room_id)?;
        let mut opts = MessagesOptions::backward();
        opts.limit = UInt::from(limit);
        let resp = room.messages(opts).await?;
        let mut raw: Vec<Value> = resp.chunk.iter().filter_map(|e| raw_json(e.raw())).collect();
        raw.reverse(); // backward pagination returns newest first
        let mut msgs = build_main_timeline(&raw, &self.user_id());
        Self::fill_sender_names(&room, &mut msgs).await;
        Ok(msgs)
    }

    /// A thread: the root message followed by its replies, oldest first.
    pub async fn thread(&self, room_id: &str, root_id: &str, limit: u32) -> Result<Vec<Message>> {
        let room = self.room(room_id)?;
        let root_eid: OwnedEventId = <&EventId>::try_from(root_id)?.to_owned();
        let own = self.user_id();
        let root_ev = room.event(&root_eid, None).await?;
        let mut msgs: Vec<Message> = raw_json(root_ev.raw()).and_then(|v| parse_event(&v, &own)).into_iter().collect();
        let opts = RelationsOptions {
            dir: Direction::Forward,
            limit: Some(UInt::from(limit)),
            include_relations: IncludeRelations::RelationsOfType(RelationType::Thread),
            ..Default::default()
        };
        let rel = room.relations(root_eid, opts).await?;
        let raw: Vec<Value> = rel.chunk.iter().filter_map(|e| raw_json(e.raw())).collect();
        // Apply edits within the thread too.
        let mut replies = build_main_timeline(&raw, &own);
        // build_main_timeline drops thread replies from "main", so parse them directly instead.
        if replies.is_empty() {
            replies = raw.iter().filter_map(|v| parse_event(v, &own)).collect();
        }
        msgs.extend(replies.into_iter().filter(|m| m.event_id != root_id));
        msgs.sort_by_key(|m| m.ts);
        Self::fill_sender_names(&room, &mut msgs).await;
        Ok(msgs)
    }

    /// Send a text message (markdown allowed). With `thread_root`, the
    /// message is sent as an `m.thread` reply (Slack-style thread).
    pub async fn send_text(&self, room_id: &str, body: &str, thread_root: Option<&str>) -> Result<String> {
        let room = self.room(room_id)?;
        let mut content = RoomMessageEventContent::text_markdown(body);
        if let Some(root) = thread_root {
            let root_eid: OwnedEventId = <&EventId>::try_from(root)?.to_owned();
            // Fallback reply points at the latest event we know in the thread.
            let latest = self
                .thread(room_id, root, 50)
                .await
                .ok()
                .and_then(|t| t.last().map(|m| m.event_id.clone()))
                .and_then(|id| OwnedEventId::try_from(id).ok())
                .unwrap_or_else(|| root_eid.clone());
            content.relates_to = Some(Relation::Thread(Thread::plain(root_eid, latest)));
        }
        let resp = room.send(content).await?;
        Ok(resp.response.event_id.to_string())
    }

    /// Plain-Matrix user directory search (fallback for the new-chat dialog
    /// when crosschatd's bridge contact search is unavailable).
    pub async fn search_users(&self, term: &str, limit: u64) -> Result<Vec<UserResult>> {
        let resp = self.client.search_users(term, limit).await?;
        Ok(resp
            .results
            .into_iter()
            .map(|u| UserResult { user_id: u.user_id.to_string(), display_name: u.display_name })
            .collect())
    }

    /// Open (or create) a DM with a Matrix user. Returns the room id.
    pub async fn create_dm(&self, user_id: &str) -> Result<String> {
        let uid = <&UserId>::try_from(user_id)?;
        if let Some(room) = self.client.get_dm_room(uid) {
            return Ok(room.room_id().to_string());
        }
        Ok(self.client.create_dm(uid).await?.room_id().to_string())
    }

    /// Create a private group room and invite users. Returns the room id.
    pub async fn create_group(&self, name: &str, invites: &[String]) -> Result<String> {
        let mut req = create_room::v3::Request::new();
        req.name = Some(name.to_owned());
        req.invite = invites
            .iter()
            .map(|u| UserId::parse(u.as_str()))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(self.client.create_room(req).await?.room_id().to_string())
    }

    /// Join a room by id or alias.
    pub async fn join(&self, room_id_or_alias: &str) -> Result<String> {
        use matrix_sdk::ruma::OwnedRoomOrAliasId;
        let id = OwnedRoomOrAliasId::try_from(room_id_or_alias)?;
        Ok(self.client.join_room_by_id_or_alias(&id, &[]).await?.room_id().to_string())
    }

    /// Log out and wipe local state.
    pub async fn logout(&self) -> Result<()> {
        self.stop_sync();
        if let Err(e) = self.client.logout().await {
            warn!("server-side logout failed: {e}");
        }
        let _ = std::fs::remove_file(session_path(&self.data_dir));
        let _ = std::fs::remove_dir_all(self.data_dir.join("store"));
        Ok(())
    }
}

/// Validate a homeserver before login: returns the supported spec versions.
pub async fn probe_homeserver(url: &str) -> Result<Vec<String>> {
    let base = url.trim_end_matches('/');
    let resp = reqwest_get_json(&format!("{base}/_matrix/client/versions")).await?;
    let versions = resp
        .get("versions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("not a Matrix homeserver"))?;
    let out: Vec<String> = versions.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    if out.is_empty() {
        bail!("homeserver reports no versions");
    }
    Ok(out)
}

async fn reqwest_get_json(url: &str) -> Result<Value> {
    let bytes = matrix_sdk::reqwest::get(url).await?.error_for_status()?.bytes().await?;
    Ok(serde_json::from_slice(&bytes)?)
}
