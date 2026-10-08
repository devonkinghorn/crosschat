//! The Dart-facing API. Everything here is a thin conversion layer over
//! `crosschat-core`; Dart never sees matrix-sdk types.

use crate::frb_generated::StreamSink;
use anyhow::{Result, anyhow};
use crosschat_core as core;
use std::future::Future;
use std::sync::{Mutex, OnceLock};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("crosschat-core")
            .build()
            .expect("tokio runtime")
    })
}

/// Run a future on our own tokio runtime (matrix-sdk needs a tokio context).
async fn on_rt<T: Send + 'static>(
    f: impl Future<Output = Result<T>> + Send + 'static,
) -> Result<T> {
    runtime()
        .spawn(f)
        .await
        .map_err(|e| anyhow!("task failed: {e}"))?
}

fn slot() -> &'static Mutex<Option<core::CrosschatClient>> {
    static CLIENT: OnceLock<Mutex<Option<core::CrosschatClient>>> = OnceLock::new();
    CLIENT.get_or_init(|| Mutex::new(None))
}

fn client() -> Result<core::CrosschatClient> {
    slot()
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("not logged in"))
}

pub struct SessionInfo {
    pub user_id: String,
    pub device_id: String,
    pub homeserver: String,
    pub access_token: String,
}

pub struct ThreadInfo {
    pub reply_count: u32,
    pub latest_reply_ts: Option<i64>,
    pub latest_reply_body: Option<String>,
    pub participants: Vec<String>,
}

pub struct ChatMessage {
    pub event_id: String,
    pub sender: String,
    pub sender_name: String,
    pub body: String,
    /// `text`, `notice`, `emote`, `image`, `file`, `video`, `audio`,
    /// `sticker`, `undecryptable`, `redacted`, `other`.
    pub kind: String,
    pub ts: i64,
    pub thread_root: Option<String>,
    pub in_reply_to: Option<String>,
    pub thread: Option<ThreadInfo>,
    pub edited: bool,
    pub is_own: bool,
    /// `mxc://` avatar of the sender in this room.
    pub sender_avatar: Option<String>,
    pub media: Option<ChatMedia>,
    pub reactions: Vec<ChatReaction>,
    pub tapback: Option<ChatTapback>,
}

/// Attachment; pass `source` to [`media_bytes`].
pub struct ChatMedia {
    pub source: String,
    pub mimetype: Option<String>,
    pub size: Option<u64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    pub filename: String,
    pub caption: Option<String>,
    pub thumbnail_source: Option<String>,
}

pub struct ChatReaction {
    pub key: String,
    pub senders: Vec<String>,
    pub own: bool,
}

/// SMS/RCS tapback fallback text ("Loved “…”"), see `crosschat_core::Tapback`.
pub struct ChatTapback {
    pub key: String,
    pub removed: bool,
    pub target_text: Option<String>,
    pub truncated: bool,
    pub target_kind: Option<String>,
}

pub struct ChatRoom {
    pub room_id: String,
    pub name: String,
    pub topic: Option<String>,
    pub is_dm: bool,
    pub unread: u64,
    pub highlights: u64,
    pub last_ts: i64,
    pub last_message: Option<String>,
    pub network_id: Option<String>,
    pub network_name: Option<String>,
    pub threads_supported: Option<bool>,
    /// Bridge identity, for grouping chats per bridge login (see
    /// `crosschat_core::NetworkInfo`).
    pub bridge_id: Option<String>,
    pub bridge_bot: Option<String>,
    pub protocol_id: Option<String>,
    pub protocol_name: Option<String>,
    pub login_id: Option<String>,
    pub room_type: Option<String>,
    /// `m.marked_unread` / `com.famedly.marked_unread`.
    pub marked_unread: bool,
}

pub struct DirectoryUser {
    pub user_id: String,
    pub display_name: Option<String>,
}

/// Update pushed from the sync loop. `kind` is `rooms_changed`,
/// `new_message` (with `room_id` + `message`), `timeline_changed` (with
/// `room_id`: reactions, edits, redactions, member names changed) or
/// `sync_state` (with `state`).
/// A flat struct keeps the generated Dart free of code-gen dependencies.
pub struct CoreUpdate {
    pub kind: String,
    pub room_id: Option<String>,
    pub message: Option<ChatMessage>,
    pub state: Option<String>,
}

impl CoreUpdate {
    fn simple(kind: &str) -> Self {
        Self {
            kind: kind.into(),
            room_id: None,
            message: None,
            state: None,
        }
    }
}

fn session_info(c: &core::CrosschatClient) -> SessionInfo {
    SessionInfo {
        user_id: c.user_id(),
        device_id: c.device_id(),
        homeserver: c.homeserver(),
        access_token: c.access_token().unwrap_or_default(),
    }
}

fn kind_str(k: &core::MessageKind) -> String {
    use core::MessageKind::*;
    match k {
        Text => "text",
        Notice => "notice",
        Emote => "emote",
        Image => "image",
        File => "file",
        Video => "video",
        Audio => "audio",
        Sticker => "sticker",
        Undecryptable => "undecryptable",
        Redacted => "redacted",
        Other => "other",
    }
    .to_string()
}

fn msg(m: core::Message) -> ChatMessage {
    ChatMessage {
        kind: kind_str(&m.kind),
        event_id: m.event_id,
        sender: m.sender,
        sender_name: m.sender_name,
        body: m.body,
        ts: m.ts,
        thread_root: m.thread_root,
        in_reply_to: m.in_reply_to,
        thread: m.thread.map(|t| ThreadInfo {
            reply_count: t.reply_count,
            latest_reply_ts: t.latest_reply_ts,
            latest_reply_body: t.latest_reply_body,
            participants: t.participants,
        }),
        edited: m.edited,
        is_own: m.is_own,
        sender_avatar: m.sender_avatar,
        media: m.media.map(|x| ChatMedia {
            source: x.source,
            mimetype: x.mimetype,
            size: x.size,
            width: x.width,
            height: x.height,
            duration_ms: x.duration_ms,
            filename: x.filename,
            caption: x.caption,
            thumbnail_source: x.thumbnail_source,
        }),
        reactions: m
            .reactions
            .into_iter()
            .map(|r| ChatReaction {
                key: r.key,
                senders: r.senders,
                own: r.own,
            })
            .collect(),
        tapback: m.tapback.map(|t| ChatTapback {
            key: t.key,
            removed: t.removed,
            target_text: t.target_text,
            truncated: t.truncated,
            target_kind: t.target_kind,
        }),
    }
}

fn room(r: core::RoomSummary) -> ChatRoom {
    ChatRoom {
        room_id: r.room_id,
        name: r.name,
        topic: r.topic,
        is_dm: r.is_dm,
        unread: r.unread,
        highlights: r.highlights,
        last_ts: r.last_ts,
        last_message: r.last_message,
        network_id: r.network.as_ref().map(|n| n.id.clone()),
        network_name: r.network.as_ref().map(|n| n.display_name.clone()),
        threads_supported: r.threads_supported,
        bridge_id: r.network.as_ref().and_then(|n| n.bridge_id.clone()),
        bridge_bot: r.network.as_ref().and_then(|n| n.bridge_bot.clone()),
        protocol_id: r.network.as_ref().map(|n| n.protocol_id.clone()),
        protocol_name: r.network.as_ref().map(|n| n.protocol_name.clone()),
        login_id: r.network.as_ref().and_then(|n| n.login_id.clone()),
        room_type: r.network.and_then(|n| n.room_type),
        marked_unread: r.marked_unread,
    }
}

/// Check that a URL is a Matrix homeserver; returns spec versions.
pub async fn probe_homeserver(url: String) -> Result<Vec<String>> {
    on_rt(async move { core::probe_homeserver(&url).await }).await
}

pub async fn restore_session(data_dir: String) -> Result<Option<SessionInfo>> {
    on_rt(async move {
        let Some(c) = core::CrosschatClient::restore(data_dir).await? else {
            return Ok(None);
        };
        let info = session_info(&c);
        *slot().lock().unwrap() = Some(c);
        Ok(Some(info))
    })
    .await
}

pub async fn login(
    homeserver: String,
    username: String,
    password: String,
    data_dir: String,
    device_name: String,
) -> Result<SessionInfo> {
    on_rt(async move {
        let c =
            core::CrosschatClient::login(&homeserver, &username, &password, data_dir, &device_name)
                .await?;
        let info = session_info(&c);
        *slot().lock().unwrap() = Some(c);
        Ok(info)
    })
    .await
}

/// Stream of core updates. Starts the background sync loop.
pub fn subscribe_updates(sink: StreamSink<CoreUpdate>) -> Result<()> {
    let c = client()?;
    let mut rx = c.subscribe();
    runtime().spawn(async move {
        c.start_sync();
        loop {
            let ev = match rx.recv().await {
                Ok(ev) => ev,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    core::CoreEvent::RoomsChanged
                }
                Err(_) => break,
            };
            let out = match ev {
                core::CoreEvent::RoomsChanged => CoreUpdate::simple("rooms_changed"),
                core::CoreEvent::NewMessage { room_id, message } => CoreUpdate {
                    room_id: Some(room_id),
                    message: Some(msg(message)),
                    ..CoreUpdate::simple("new_message")
                },
                core::CoreEvent::TimelineChanged { room_id } => CoreUpdate {
                    room_id: Some(room_id),
                    ..CoreUpdate::simple("timeline_changed")
                },
                core::CoreEvent::SyncState { state } => CoreUpdate {
                    state: Some(state),
                    ..CoreUpdate::simple("sync_state")
                },
            };
            if sink.add(out).is_err() {
                break;
            }
        }
    });
    Ok(())
}

pub async fn sync_once() -> Result<()> {
    let c = client()?;
    on_rt(async move { c.sync_once().await }).await
}

pub async fn list_rooms() -> Result<Vec<ChatRoom>> {
    let c = client()?;
    on_rt(async move { Ok(c.rooms().await?.into_iter().map(room).collect()) }).await
}

pub async fn room_timeline(room_id: String, limit: u32) -> Result<Vec<ChatMessage>> {
    let c = client()?;
    on_rt(async move {
        Ok(c.timeline(&room_id, limit)
            .await?
            .into_iter()
            .map(msg)
            .collect())
    })
    .await
}

pub async fn thread_timeline(
    room_id: String,
    root_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>> {
    let c = client()?;
    on_rt(async move {
        Ok(c.thread(&room_id, &root_id, limit)
            .await?
            .into_iter()
            .map(msg)
            .collect())
    })
    .await
}

pub async fn send_text(
    room_id: String,
    body: String,
    thread_root: Option<String>,
) -> Result<String> {
    let c = client()?;
    on_rt(async move { c.send_text(&room_id, &body, thread_root.as_deref()).await }).await
}

/// Mark a room read up to `event_id` (default: its latest message): read
/// receipt + fully-read marker, clears marked-unread. Returns the event id.
pub async fn mark_read(room_id: String, event_id: Option<String>) -> Result<Option<String>> {
    let c = client()?;
    on_rt(async move { c.mark_read(&room_id, event_id.as_deref()).await }).await
}

/// Set / clear the room's marked-unread flag.
pub async fn set_marked_unread(room_id: String, unread: bool) -> Result<()> {
    let c = client()?;
    on_rt(async move { c.set_marked_unread(&room_id, unread).await }).await
}

/// Bytes of an attachment (decrypted) or avatar. `source` is
/// `ChatMedia::source` / `thumbnail_source` or an `mxc://` URL; with a size,
/// a server thumbnail is requested where possible.
pub async fn media_bytes(
    source: String,
    thumb_width: Option<u32>,
    thumb_height: Option<u32>,
) -> Result<Vec<u8>> {
    let c = client()?;
    let thumb = thumb_width.zip(thumb_height);
    on_rt(async move { c.media(&source, thumb).await }).await
}

pub async fn search_directory(term: String, limit: u32) -> Result<Vec<DirectoryUser>> {
    let c = client()?;
    on_rt(async move {
        Ok(c.search_users(&term, limit as u64)
            .await?
            .into_iter()
            .map(|u| DirectoryUser {
                user_id: u.user_id,
                display_name: u.display_name,
            })
            .collect())
    })
    .await
}

pub async fn create_dm(user_id: String) -> Result<String> {
    let c = client()?;
    on_rt(async move { c.create_dm(&user_id).await }).await
}

pub async fn create_group(name: String, invites: Vec<String>) -> Result<String> {
    let c = client()?;
    on_rt(async move { c.create_group(&name, &invites).await }).await
}

pub async fn join_room(room_id_or_alias: String) -> Result<String> {
    let c = client()?;
    on_rt(async move { c.join(&room_id_or_alias).await }).await
}

pub async fn logout() -> Result<()> {
    let c = slot().lock().unwrap().take();
    if let Some(c) = c {
        on_rt(async move { c.logout().await }).await?;
    }
    Ok(())
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
