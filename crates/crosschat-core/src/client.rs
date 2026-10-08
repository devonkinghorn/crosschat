//! `CrosschatClient`: the only Matrix API the UI sees.
//!
//! Alpha implementation notes:
//! * Uses classic `/sync` (works on every homeserver). Moving the room list to
//!   matrix-sdk-ui's `RoomListService` (Simplified Sliding Sync) is the next
//!   step; the public API here is shaped so callers won't change.
//! * Session tokens are persisted to `<data_dir>/session.json` with 0600
//!   permissions. Moving them into the OS keychain is tracked in the roadmap.

use crate::content;
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
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    room::{IncludeRelations, MessagesOptions, RelationsOptions},
    ruma::{
        EventId, OwnedEventId, OwnedMxcUri, RoomId, UInt, UserId,
        api::{
            Direction,
            client::{read_marker::set_read_marker, room::create_room},
        },
        events::{
            AnyRoomAccountDataEventContent, RoomAccountDataEventType, StateEventType,
            receipt::{ReceiptThread, ReceiptType},
            relation::{RelationType, Thread},
            room::{
                MediaSource, message::{Relation, RoomMessageEventContent},
            },
        },
        serde::Raw,
    },
    sync::State,
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

/// (display name, avatar mxc) as fetched from the profile API.
type ProfileEntry = (Option<String>, Option<String>);

/// Cheaply clonable handle to a logged-in Matrix account.
#[derive(Clone)]
pub struct CrosschatClient {
    client: Client,
    data_dir: PathBuf,
    events: broadcast::Sender<CoreEvent>,
    last: Arc<Mutex<HashMap<String, LastMessage>>>,
    sync_task: Arc<Mutex<Option<JoinHandle<()>>>>,
    /// Global profiles of senders that have no room member info.
    profiles: Arc<Mutex<HashMap<String, Option<ProfileEntry>>>>,
    /// Last read receipt we sent per room (Tuwunel re-emits repeated
    /// receipts to bridges, so never send the same one twice).
    receipts: Arc<Mutex<HashMap<String, String>>>,
    /// Marked-unread flags we wrote that sync hasn't echoed yet.
    marked: Arc<Mutex<HashMap<String, bool>>>,
}

/// `(display name, avatar mxc)` of a sender as shown in a room.
#[derive(Clone, Default)]
struct SenderProfile {
    name: String,
    avatar: Option<String>,
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
            profiles: Default::default(),
            receipts: Default::default(),
            marked: Default::default(),
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
        let session = client
            .matrix_auth()
            .session()
            .ok_or_else(|| anyhow!("no session after login"))?;
        let stored = StoredSession {
            homeserver: client.homeserver().to_string(),
            session,
        };
        write_private(
            &session_path(&data_dir),
            &serde_json::to_vec_pretty(&stored)?,
        )?;
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
        client
            .matrix_auth()
            .restore_session(stored.session, RoomLoadSettings::default())
            .await?;
        Ok(Some(Self::wrap(client, data_dir)))
    }

    pub fn user_id(&self) -> String {
        self.client
            .user_id()
            .map(|u| u.to_string())
            .unwrap_or_default()
    }

    pub fn device_id(&self) -> String {
        self.client
            .device_id()
            .map(|d| d.to_string())
            .unwrap_or_default()
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

    async fn record_sync(&self, response: &matrix_sdk::sync::SyncResponse) {
        let own = self.user_id();
        let mut changed = !response.rooms.joined.is_empty()
            || !response.rooms.invited.is_empty()
            || !response.rooms.left.is_empty();
        for (room_id, update) in &response.rooms.joined {
            let room = self.client.get_room(room_id);
            let mut cache: HashMap<String, SenderProfile> = HashMap::new();
            // Reactions, edits, redactions and member changes alter messages
            // that may already be on screen.
            let mut timeline_changed = !update.ambiguity_changes.is_empty()
                || state_has_member(&update.state);
            for ev in &update.timeline.events {
                let Some(json) = raw_json(ev.raw()) else {
                    continue;
                };
                let ty = json.get("type").and_then(Value::as_str).unwrap_or("");
                let is_edit = json
                    .pointer("/content/m.relates_to/rel_type")
                    .and_then(Value::as_str)
                    == Some("m.replace");
                if matches!(ty, "m.reaction" | "m.room.redaction" | "m.room.member") || is_edit {
                    timeline_changed = true;
                }
                if let Some(mut msg) = parse_event(&json, &own) {
                    if let Some(room) = &room {
                        let p = self.sender_profile(room, &msg.sender, &mut cache).await;
                        msg.sender_name = p.name;
                        msg.sender_avatar = p.avatar;
                    }
                    if msg.thread_root.is_none() {
                        self.last.lock().unwrap().insert(
                            room_id.to_string(),
                            LastMessage {
                                ts: msg.ts,
                                body: content::preview(&msg),
                            },
                        );
                    }
                    let _ = self.events.send(CoreEvent::NewMessage {
                        room_id: room_id.to_string(),
                        message: msg,
                    });
                    changed = true;
                }
            }
            if timeline_changed {
                let _ = self.events.send(CoreEvent::TimelineChanged {
                    room_id: room_id.to_string(),
                });
            }
            // Our marked-unread writes are echoed back as account data.
            if !update.account_data.is_empty() {
                self.marked.lock().unwrap().remove(room_id.as_str());
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
        self.record_sync(&response).await;
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
            let _ = this.events.send(CoreEvent::SyncState {
                state: "syncing".into(),
            });
            loop {
                let settings = SyncSettings::default().timeout(Duration::from_secs(30));
                match this.client.sync_once(settings).await {
                    Ok(response) => this.record_sync(&response).await,
                    Err(e) => {
                        warn!("sync error: {e}");
                        let _ = this.events.send(CoreEvent::SyncState {
                            state: format!("error: {e}"),
                        });
                        tokio::time::sleep(Duration::from_secs(5)).await;
                        let _ = this.events.send(CoreEvent::SyncState {
                            state: "syncing".into(),
                        });
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
        self.client
            .get_room(id)
            .ok_or_else(|| anyhow!("unknown room {room_id}"))
    }

    async fn state_content(room: &Room, ty: &str) -> Option<Value> {
        let events = room.get_state_events(StateEventType::from(ty)).await.ok()?;
        events.iter().find_map(|e| match e {
            RawAnySyncOrStrippedState::Sync(raw) => {
                raw_json(raw).and_then(|v| v.get("content").cloned())
            }
            RawAnySyncOrStrippedState::Stripped(raw) => {
                raw_json(raw).and_then(|v| v.get("content").cloned())
            }
        })
    }

    /// `(state_key, content)` of the state events of one type.
    async fn state_events(room: &Room, ty: &str) -> Vec<(String, Value)> {
        let Ok(events) = room.get_state_events(StateEventType::from(ty)).await else {
            return Vec::new();
        };
        events
            .iter()
            .filter_map(|e| {
                let v = match e {
                    RawAnySyncOrStrippedState::Sync(raw) => raw_json(raw),
                    RawAnySyncOrStrippedState::Stripped(raw) => raw_json(raw),
                }?;
                let key = v
                    .get("state_key")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                Some((key, v.get("content")?.clone()))
            })
            .collect()
    }

    async fn network_of(room: &Room) -> Option<NetworkInfo> {
        for ty in ["m.bridge", "uk.half-shot.bridge"] {
            for (key, content) in Self::state_events(room, ty).await {
                if let Some(n) = parse_bridge_state(&content, Some(&key)) {
                    return Some(n);
                }
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
            // Spaces (e.g. a bridge's per-account space) aren't chats.
            if room.is_space() {
                continue;
            }
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
            let local_mark = self.marked.lock().unwrap().get(&room_id).copied();
            let marked_unread = match local_mark {
                Some(v) => v,
                None => content::marked_unread(
                    Self::account_data_content(&room, "m.marked_unread").await.as_ref(),
                    Self::account_data_content(&room, "com.famedly.marked_unread")
                        .await
                        .as_ref(),
                ),
            };
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
                marked_unread,
                room_id,
            });
        }
        out.sort_by(|a, b| b.last_ts.cmp(&a.last_ts).then_with(|| a.name.cmp(&b.name)));
        Ok(out)
    }

    /// Display name and avatar of a sender in a room: the member's room
    /// display name (disambiguated), else their global profile, else a
    /// readable fallback. Never a raw MXID.
    async fn sender_profile(
        &self,
        room: &Room,
        sender: &str,
        cache: &mut HashMap<String, SenderProfile>,
    ) -> SenderProfile {
        if let Some(p) = cache.get(sender) {
            return p.clone();
        }
        let Ok(uid) = <&UserId>::try_from(sender) else {
            return SenderProfile {
                name: content::fallback_name(sender),
                avatar: None,
            };
        };
        let member = room.get_member_no_sync(uid).await.ok().flatten();
        let (mut name, mut avatar, ambiguous) = match &member {
            Some(m) => (
                m.display_name().map(str::to_owned),
                m.avatar_url().map(|u| u.to_string()),
                m.name_ambiguous(),
            ),
            None => (None, None, false),
        };
        if name.is_none() {
            let known = self.profiles.lock().unwrap().get(sender).cloned();
            let profile = match known {
                Some(p) => p,
                None => {
                    let fetched = self
                        .client
                        .account()
                        .fetch_user_profile_of(uid)
                        .await
                        .ok()
                        .map(|p| {
                            let field = |k: &str| p.get(k).and_then(Value::as_str).map(str::to_owned);
                            (field("displayname"), field("avatar_url"))
                        });
                    self.profiles
                        .lock()
                        .unwrap()
                        .insert(sender.to_owned(), fetched.clone());
                    fetched
                }
            };
            if let Some((n, a)) = profile {
                name = n;
                avatar = avatar.or(a);
            }
        }
        let p = SenderProfile {
            name: content::display_name_for(sender, name.as_deref(), ambiguous),
            avatar,
        };
        cache.insert(sender.to_owned(), p.clone());
        p
    }

    async fn fill_sender_names(&self, room: &Room, msgs: &mut [Message]) {
        let mut cache: HashMap<String, SenderProfile> = HashMap::new();
        for m in msgs.iter_mut() {
            let p = self.sender_profile(room, &m.sender, &mut cache).await;
            m.sender_name = p.name;
            m.sender_avatar = p.avatar;
        }
    }

    /// The channel timeline (thread replies folded into root summaries),
    /// oldest first. `limit` is the number of raw events fetched.
    pub async fn timeline(&self, room_id: &str, limit: u32) -> Result<Vec<Message>> {
        let room = self.room(room_id)?;
        let mut opts = MessagesOptions::backward();
        opts.limit = UInt::from(limit);
        let resp = room.messages(opts).await?;
        let mut raw: Vec<Value> = resp
            .chunk
            .iter()
            .filter_map(|e| raw_json(e.raw()))
            .collect();
        raw.reverse(); // backward pagination returns newest first
        let mut msgs = build_main_timeline(&raw, &self.user_id());
        self.fill_sender_names(&room, &mut msgs).await;
        Ok(msgs)
    }

    /// A thread: the root message followed by its replies, oldest first.
    pub async fn thread(&self, room_id: &str, root_id: &str, limit: u32) -> Result<Vec<Message>> {
        let room = self.room(room_id)?;
        let root_eid: OwnedEventId = <&EventId>::try_from(root_id)?.to_owned();
        let own = self.user_id();
        let root_ev = room.event(&root_eid, None).await?;
        let mut msgs: Vec<Message> = raw_json(root_ev.raw())
            .and_then(|v| parse_event(&v, &own))
            .into_iter()
            .collect();
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
        self.fill_sender_names(&room, &mut msgs).await;
        Ok(msgs)
    }

    /// Send a text message (markdown allowed). With `thread_root`, the
    /// message is sent as an `m.thread` reply (Slack-style thread).
    pub async fn send_text(
        &self,
        room_id: &str,
        body: &str,
        thread_root: Option<&str>,
    ) -> Result<String> {
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

    /// Mark a room read up to `event_id` (default: its latest message):
    /// public read receipt + `m.fully_read`, so the server clears the unread
    /// counts and bridges mark the chat read on the remote network; also
    /// clears a marked-unread flag. Returns the event marked, if any.
    pub async fn mark_read(&self, room_id: &str, event_id: Option<&str>) -> Result<Option<String>> {
        let room = self.room(room_id)?;
        let target = match event_id {
            Some(id) => Some(id.to_owned()),
            None => self.latest_event_id(&room).await?,
        };
        if let Some(target) = &target {
            let eid: OwnedEventId = <&EventId>::try_from(target.as_str())?.to_owned();
            let own = self.client.user_id().ok_or_else(|| anyhow!("not logged in"))?;
            let already = self.receipts.lock().unwrap().get(room_id) == Some(target)
                || room
                    .load_user_receipt(ReceiptType::Read, &ReceiptThread::Unthreaded, own)
                    .await
                    .ok()
                    .flatten()
                    .is_some_and(|(id, _)| id == eid);
            if !already {
                let mut req = set_read_marker::v3::Request::new(room.room_id().to_owned());
                req.fully_read = Some(eid.clone());
                req.read_receipt = Some(eid);
                self.client.send(req).await?;
                self.receipts
                    .lock()
                    .unwrap()
                    .insert(room_id.to_owned(), target.clone());
            }
        }
        let flagged = self.marked.lock().unwrap().get(room_id).copied();
        if flagged.unwrap_or_else(|| room.is_marked_unread()) {
            self.write_marked_unread(&room, false).await?;
        }
        Ok(target)
    }

    /// Set or clear the room's marked-unread flag (MSC2867: written as
    /// `m.marked_unread` and the unstable `com.famedly.marked_unread`).
    pub async fn set_marked_unread(&self, room_id: &str, unread: bool) -> Result<()> {
        let room = self.room(room_id)?;
        self.write_marked_unread(&room, unread).await
    }

    async fn write_marked_unread(&self, room: &Room, unread: bool) -> Result<()> {
        let content: Raw<AnyRoomAccountDataEventContent> = Raw::from_json(
            serde_json::value::to_raw_value(&serde_json::json!({ "unread": unread }))?,
        );
        for ty in ["m.marked_unread", "com.famedly.marked_unread"] {
            room.set_account_data_raw(RoomAccountDataEventType::from(ty), content.clone())
                .await?;
        }
        self.marked
            .lock()
            .unwrap()
            .insert(room.room_id().to_string(), unread);
        let _ = self.events.send(CoreEvent::RoomsChanged);
        Ok(())
    }

    async fn latest_event_id(&self, room: &Room) -> Result<Option<String>> {
        let mut opts = MessagesOptions::backward();
        opts.limit = UInt::from(20u32);
        let resp = room.messages(opts).await?;
        let raw: Vec<Value> = resp.chunk.iter().filter_map(|e| raw_json(e.raw())).collect();
        Ok(content::pick_read_target(&raw))
    }

    async fn account_data_content(room: &Room, ty: &str) -> Option<Value> {
        let raw = room
            .account_data(RoomAccountDataEventType::from(ty))
            .await
            .ok()??;
        raw_json(&raw).and_then(|v| v.get("content").cloned())
    }

    /// Download an attachment (decrypting it in encrypted rooms). `source`
    /// is [`content::MediaInfo::source`] or a bare `mxc://` URL (avatars).
    /// With `thumbnail`, asks the server for a scaled-down version (plain
    /// media only; encrypted media has no server-side thumbnails). Uses the
    /// authenticated media API when the server supports it (Matrix 1.11),
    /// the legacy one otherwise, and the SDK's media cache.
    pub async fn media(&self, source: &str, thumbnail: Option<(u32, u32)>) -> Result<Vec<u8>> {
        let source = parse_media_source(source)?;
        let format = match (&source, thumbnail) {
            (MediaSource::Plain(_), Some((w, h))) => MediaFormat::Thumbnail(
                MediaThumbnailSettings::new(UInt::from(w), UInt::from(h)),
            ),
            _ => MediaFormat::File,
        };
        let request = MediaRequestParameters { source, format };
        Ok(self.client.media().get_media_content(&request, true).await?)
    }

    /// Plain-Matrix user directory search (fallback for the new-chat dialog
    /// when crosschatd's bridge contact search is unavailable).
    pub async fn search_users(&self, term: &str, limit: u64) -> Result<Vec<UserResult>> {
        let resp = self.client.search_users(term, limit).await?;
        Ok(resp
            .results
            .into_iter()
            .map(|u| UserResult {
                user_id: u.user_id.to_string(),
                display_name: u.display_name,
            })
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
        Ok(self
            .client
            .join_room_by_id_or_alias(&id, &[])
            .await?
            .room_id()
            .to_string())
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

fn state_has_member(state: &State) -> bool {
    let events = match state {
        State::Before(evs) | State::After(evs) => evs,
    };
    events.iter().any(|e| {
        raw_json(e)
            .and_then(|v| v.get("type").and_then(Value::as_str).map(|t| t == "m.room.member"))
            .unwrap_or(false)
    })
}

/// `{"url": "mxc://…"}`, `{"file": {…}}` or a bare `mxc://` URL.
fn parse_media_source(source: &str) -> Result<MediaSource> {
    if source.starts_with("mxc://") {
        return Ok(MediaSource::Plain(OwnedMxcUri::from(source)));
    }
    let v: Value = serde_json::from_str(source).context("invalid media source")?;
    if let Some(file) = v.get("file") {
        return Ok(MediaSource::Encrypted(Box::new(serde_json::from_value(
            file.clone(),
        )?)));
    }
    let url = v
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("media source has no url"))?;
    Ok(MediaSource::Plain(OwnedMxcUri::from(url)))
}

/// Validate a homeserver before login: returns the supported spec versions.
pub async fn probe_homeserver(url: &str) -> Result<Vec<String>> {
    let base = url.trim_end_matches('/');
    let resp = reqwest_get_json(&format!("{base}/_matrix/client/versions")).await?;
    let versions = resp
        .get("versions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("not a Matrix homeserver"))?;
    let out: Vec<String> = versions
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    if out.is_empty() {
        bail!("homeserver reports no versions");
    }
    Ok(out)
}

async fn reqwest_get_json(url: &str) -> Result<Value> {
    let bytes = matrix_sdk::reqwest::get(url)
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    Ok(serde_json::from_slice(&bytes)?)
}
