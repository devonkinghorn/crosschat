//! Plain data types shared with the UI layer, plus pure helpers that turn raw
//! Matrix event JSON into them. Keeping these free of matrix-sdk types means
//! the FFI layer (flutter_rust_bridge) only ever sees simple structs, and the
//! parsing logic can be unit-tested without a homeserver.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

/// What kind of message a timeline item is, reduced to what the UI renders.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageKind {
    Text,
    Notice,
    Emote,
    Image,
    File,
    Video,
    Audio,
    Sticker,
    /// Encrypted event we could not decrypt (missing keys).
    Undecryptable,
    /// Redacted / deleted message.
    Redacted,
    Other,
}

/// Summary of a thread rooted at a message (Slack-style "N replies" row).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadSummary {
    pub reply_count: u32,
    pub latest_reply_ts: Option<i64>,
    pub latest_reply_body: Option<String>,
    /// MXIDs of the most recent repliers we know about (may be partial until
    /// the thread is opened).
    pub participants: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub event_id: String,
    pub sender: String,
    pub sender_name: String,
    pub body: String,
    pub kind: MessageKind,
    pub ts: i64,
    /// Set when this event is a reply inside a thread (`m.thread` relation).
    pub thread_root: Option<String>,
    /// Set when the event is an inline (rich) reply.
    pub in_reply_to: Option<String>,
    pub thread: Option<ThreadSummary>,
    pub edited: bool,
    pub is_own: bool,
}

/// Bridged network a room belongs to, derived from `m.bridge` state or from
/// the ghost user namespace.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkInfo {
    /// Stable protocol id, e.g. `imessage`, `gmessages`, `slack`, `groupme`.
    pub id: String,
    pub display_name: String,
    pub bridge_bot: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoomSummary {
    pub room_id: String,
    pub name: String,
    pub topic: Option<String>,
    pub is_dm: bool,
    pub unread: u64,
    pub highlights: u64,
    pub last_ts: i64,
    pub last_message: Option<String>,
    /// `None` for plain Matrix rooms.
    pub network: Option<NetworkInfo>,
    /// Whether the bridge declares thread support for this room. `None` means
    /// unknown (plain Matrix rooms always support threads).
    pub threads_supported: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserResult {
    pub user_id: String,
    pub display_name: Option<String>,
}

/// Events pushed to the UI as sync progresses.
// Messages dominate the event stream, so boxing them buys nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum CoreEvent {
    /// Room list changed (new room, new message, unread counts...).
    RoomsChanged,
    /// A new message arrived in a room.
    NewMessage { room_id: String, message: Message },
    /// Sync state changed (`syncing`, `error: ...`, `stopped`).
    SyncState { state: String },
}

/// Read `content.m.relates_to` of an event and return `(rel_type, event_id)`.
fn relation(content: &Value) -> Option<(String, String)> {
    let rel = content.get("m.relates_to")?;
    let rel_type = rel.get("rel_type")?.as_str()?.to_owned();
    let event_id = rel.get("event_id")?.as_str()?.to_owned();
    Some((rel_type, event_id))
}

fn in_reply_to(content: &Value) -> Option<String> {
    content
        .get("m.relates_to")?
        .get("m.in_reply_to")?
        .get("event_id")?
        .as_str()
        .map(str::to_owned)
}

/// Strip the legacy rich-reply fallback (`> <@user> quoted` lines) from a body.
pub fn strip_reply_fallback(body: &str) -> String {
    if !body.starts_with("> ") {
        return body.to_owned();
    }
    let mut lines = body.lines().peekable();
    while let Some(l) = lines.peek() {
        if l.starts_with('>') {
            lines.next();
        } else {
            break;
        }
    }
    if let Some(l) = lines.peek()
        && l.is_empty()
    {
        lines.next();
    }
    lines.collect::<Vec<_>>().join("\n")
}

/// Parse one raw timeline event (sync or `/messages` format). Returns `None`
/// for events the UI doesn't render as messages (state, edits, reactions...).
pub fn parse_event(raw: &Value, own_user: &str) -> Option<Message> {
    let ty = raw.get("type")?.as_str()?;
    if raw.get("state_key").is_some() {
        return None;
    }
    let event_id = raw.get("event_id")?.as_str()?.to_owned();
    let sender = raw.get("sender")?.as_str()?.to_owned();
    let ts = raw
        .get("origin_server_ts")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let empty = Value::Object(Default::default());
    let content = raw.get("content").unwrap_or(&empty);
    let unsigned = raw.get("unsigned");

    let redacted = unsigned.and_then(|u| u.get("redacted_because")).is_some()
        || (matches!(ty, "m.room.message" | "m.sticker")
            && content.as_object().is_some_and(|o| o.is_empty()));

    let (kind, body) = match ty {
        _ if redacted => (MessageKind::Redacted, "Message deleted".to_owned()),
        "m.room.message" => {
            if relation(content).is_some_and(|(t, _)| t == "m.replace") {
                return None; // edits are folded into their target by the caller
            }
            let body = content
                .get("body")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let kind = match content.get("msgtype").and_then(Value::as_str).unwrap_or("") {
                "m.text" => MessageKind::Text,
                "m.notice" => MessageKind::Notice,
                "m.emote" => MessageKind::Emote,
                "m.image" => MessageKind::Image,
                "m.file" => MessageKind::File,
                "m.video" => MessageKind::Video,
                "m.audio" => MessageKind::Audio,
                _ => MessageKind::Other,
            };
            let body = if in_reply_to(content).is_some() {
                strip_reply_fallback(&body)
            } else {
                body
            };
            (kind, body)
        }
        "m.sticker" => (
            MessageKind::Sticker,
            content
                .get("body")
                .and_then(Value::as_str)
                .unwrap_or("Sticker")
                .to_owned(),
        ),
        "m.room.encrypted" => (
            MessageKind::Undecryptable,
            "Unable to decrypt message".to_owned(),
        ),
        _ => return None,
    };

    let (thread_root, reply) = match relation(content) {
        Some((t, root)) if t == "m.thread" => {
            // In threads, `m.in_reply_to` with `is_falling_back` is only a fallback.
            let falling_back = content
                .get("m.relates_to")
                .and_then(|r| r.get("is_falling_back"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            (
                Some(root),
                if falling_back {
                    None
                } else {
                    in_reply_to(content)
                },
            )
        }
        _ => (None, in_reply_to(content)),
    };

    let thread = unsigned
        .and_then(|u| u.get("m.relations"))
        .and_then(|r| r.get("m.thread"))
        .map(|t| {
            let latest = t.get("latest_event");
            ThreadSummary {
                reply_count: t.get("count").and_then(Value::as_u64).unwrap_or(0) as u32,
                latest_reply_ts: latest
                    .and_then(|l| l.get("origin_server_ts"))
                    .and_then(Value::as_i64),
                latest_reply_body: latest
                    .and_then(|l| l.get("content"))
                    .and_then(|c| c.get("body"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                participants: latest
                    .and_then(|l| l.get("sender"))
                    .and_then(Value::as_str)
                    .map(|s| vec![s.to_owned()])
                    .unwrap_or_default(),
            }
        });

    let edited = unsigned
        .and_then(|u| u.get("m.relations"))
        .and_then(|r| r.get("m.replace"))
        .is_some();

    Some(Message {
        is_own: sender == own_user,
        sender_name: sender.clone(),
        event_id,
        sender,
        body,
        kind,
        ts,
        thread_root,
        in_reply_to: reply,
        thread,
        edited,
    })
}

/// Extract `(target_event_id, new_body)` from an `m.replace` edit event.
pub fn parse_edit(raw: &Value) -> Option<(String, String)> {
    let content = raw.get("content")?;
    let (t, target) = relation(content)?;
    if t != "m.replace" {
        return None;
    }
    let body = content
        .get("m.new_content")?
        .get("body")?
        .as_str()?
        .to_owned();
    Some((target, body))
}

/// Build the channel ("main") timeline from a chronological list of raw
/// events: thread replies are hidden and folded into their root's
/// [`ThreadSummary`], and edits are applied to their targets.
pub fn build_main_timeline(raw_events: &[Value], own_user: &str) -> Vec<Message> {
    let mut edits: HashMap<String, String> = HashMap::new();
    for ev in raw_events {
        if let Some((target, body)) = parse_edit(ev) {
            edits.insert(target, body); // later edits win (chronological input)
        }
    }

    let mut main: Vec<Message> = Vec::new();
    let mut replies: BTreeMap<String, Vec<Message>> = BTreeMap::new();
    for ev in raw_events {
        let Some(mut msg) = parse_event(ev, own_user) else {
            continue;
        };
        if let Some(body) = edits.get(&msg.event_id) {
            msg.body = body.clone();
            msg.edited = true;
        }
        match &msg.thread_root {
            Some(root) => replies.entry(root.clone()).or_default().push(msg),
            None => main.push(msg),
        }
    }

    for msg in &mut main {
        let Some(seen) = replies.get(&msg.event_id) else {
            continue;
        };
        let summary = msg.thread.get_or_insert_with(ThreadSummary::default);
        summary.reply_count = summary.reply_count.max(seen.len() as u32);
        if let Some(last) = seen.iter().max_by_key(|m| m.ts)
            && summary.latest_reply_ts.is_none_or(|ts| last.ts >= ts)
        {
            summary.latest_reply_ts = Some(last.ts);
            summary.latest_reply_body = Some(last.body.clone());
        }
        let mut people: Vec<String> = Vec::new();
        for m in seen.iter().rev() {
            if !people.contains(&m.sender) {
                people.push(m.sender.clone());
            }
        }
        for p in summary.participants.drain(..) {
            if !people.contains(&p) {
                people.push(p);
            }
        }
        people.truncate(5);
        summary.participants = people;
    }
    main
}

/// Parse an `m.bridge` / `uk.half-shot.bridge` state event content.
pub fn parse_bridge_state(content: &Value) -> Option<NetworkInfo> {
    let protocol = content.get("protocol")?;
    let id = protocol.get("id")?.as_str()?.to_owned();
    let display_name = protocol
        .get("displayname")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| id.clone());
    Some(NetworkInfo {
        id,
        display_name,
        bridge_bot: content
            .get("bridgebot")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

/// Read thread support from a `com.beeper.room_features` state event.
/// The capability level is an integer (>0 = supported) in current mautrix;
/// older versions used booleans.
pub fn threads_supported_from_features(content: &Value) -> Option<bool> {
    let thread = content.get("thread")?;
    if let Some(b) = thread.as_bool() {
        return Some(b);
    }
    thread.as_i64().map(|level| level > 0)
}

/// Fallback network detection from member MXIDs, using known ghost prefixes.
pub fn guess_network_from_members<'a>(
    members: impl IntoIterator<Item = &'a str>,
) -> Option<NetworkInfo> {
    const KNOWN: &[(&str, &str, &str)] = &[
        ("@imessage_", "imessage", "iMessage"),
        ("@gmessages_", "gmessages", "Google Messages"),
        ("@slack_", "slack", "Slack"),
        ("@groupme_", "groupme", "GroupMe"),
        ("@whatsapp_", "whatsapp", "WhatsApp"),
        ("@signal_", "signal", "Signal"),
        ("@telegram_", "telegram", "Telegram"),
    ];
    for m in members {
        for (prefix, id, name) in KNOWN {
            if m.starts_with(prefix) {
                return Some(NetworkInfo {
                    id: (*id).into(),
                    display_name: (*name).into(),
                    bridge_bot: None,
                });
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn msg(id: &str, sender: &str, body: &str, ts: i64) -> Value {
        json!({"type":"m.room.message","event_id":id,"sender":sender,"origin_server_ts":ts,
               "content":{"msgtype":"m.text","body":body}})
    }

    fn thread_reply(id: &str, root: &str, sender: &str, body: &str, ts: i64) -> Value {
        json!({"type":"m.room.message","event_id":id,"sender":sender,"origin_server_ts":ts,
               "content":{"msgtype":"m.text","body":body,
                 "m.relates_to":{"rel_type":"m.thread","event_id":root,"is_falling_back":true,
                   "m.in_reply_to":{"event_id":root}}}})
    }

    #[test]
    fn parses_plain_text() {
        let m = parse_event(&msg("$a", "@me:x", "hi", 5), "@me:x").unwrap();
        assert_eq!(m.body, "hi");
        assert_eq!(m.kind, MessageKind::Text);
        assert!(m.is_own);
        assert!(m.thread_root.is_none());
    }

    #[test]
    fn skips_state_and_reactions() {
        let state = json!({"type":"m.room.name","state_key":"","event_id":"$s","sender":"@a:x","content":{"name":"n"}});
        assert!(parse_event(&state, "@me:x").is_none());
        let react = json!({"type":"m.reaction","event_id":"$r","sender":"@a:x","content":{}});
        assert!(parse_event(&react, "@me:x").is_none());
    }

    #[test]
    fn thread_reply_fallback_is_not_inline_reply() {
        let m = parse_event(&thread_reply("$b", "$a", "@bob:x", "yo", 6), "@me:x").unwrap();
        assert_eq!(m.thread_root.as_deref(), Some("$a"));
        assert_eq!(m.in_reply_to, None);
    }

    #[test]
    fn main_timeline_hides_thread_replies_and_summarizes() {
        let events = vec![
            msg("$root", "@alice:x", "lunch?", 1),
            thread_reply("$r1", "$root", "@bob:x", "yes", 2),
            msg("$other", "@alice:x", "unrelated", 3),
            thread_reply("$r2", "$root", "@carol:x", "me too", 4),
        ];
        let tl = build_main_timeline(&events, "@me:x");
        assert_eq!(tl.len(), 2);
        let s = tl[0].thread.as_ref().unwrap();
        assert_eq!(s.reply_count, 2);
        assert_eq!(s.latest_reply_body.as_deref(), Some("me too"));
        assert_eq!(
            s.participants,
            vec!["@carol:x".to_string(), "@bob:x".to_string()]
        );
        assert!(tl[1].thread.is_none());
    }

    #[test]
    fn bundled_thread_summary_is_used() {
        let mut root = msg("$root", "@alice:x", "q", 1);
        root["unsigned"] = json!({"m.relations":{"m.thread":{"count":7,"current_user_participated":false,
            "latest_event":{"sender":"@dan:x","origin_server_ts":99,"content":{"body":"last"}}}}});
        let tl = build_main_timeline(&[root], "@me:x");
        let s = tl[0].thread.as_ref().unwrap();
        assert_eq!(s.reply_count, 7);
        assert_eq!(s.latest_reply_ts, Some(99));
        assert_eq!(s.participants, vec!["@dan:x".to_string()]);
    }

    #[test]
    fn edits_are_applied() {
        let edit = json!({"type":"m.room.message","event_id":"$e","sender":"@me:x","origin_server_ts":2,
            "content":{"msgtype":"m.text","body":"* fixed","m.new_content":{"msgtype":"m.text","body":"fixed"},
            "m.relates_to":{"rel_type":"m.replace","event_id":"$a"}}});
        let tl = build_main_timeline(&[msg("$a", "@me:x", "fxied", 1), edit], "@me:x");
        assert_eq!(tl.len(), 1);
        assert_eq!(tl[0].body, "fixed");
        assert!(tl[0].edited);
    }

    #[test]
    fn strips_rich_reply_fallback() {
        assert_eq!(
            strip_reply_fallback("> <@a:x> hello\n> more\n\nreal reply"),
            "real reply"
        );
        assert_eq!(strip_reply_fallback("no quote"), "no quote");
    }

    #[test]
    fn redacted_and_undecryptable() {
        let red = json!({"type":"m.room.message","event_id":"$d","sender":"@a:x","origin_server_ts":1,"content":{},
            "unsigned":{"redacted_because":{}}});
        assert_eq!(
            parse_event(&red, "@me:x").unwrap().kind,
            MessageKind::Redacted
        );
        let enc = json!({"type":"m.room.encrypted","event_id":"$c","sender":"@a:x","origin_server_ts":1,
            "content":{"algorithm":"m.megolm.v1.aes-sha2"}});
        assert_eq!(
            parse_event(&enc, "@me:x").unwrap().kind,
            MessageKind::Undecryptable
        );
    }

    #[test]
    fn bridge_state_and_features() {
        let c = json!({"bridgebot":"@slackbot:x","protocol":{"id":"slack","displayname":"Slack"}});
        let n = parse_bridge_state(&c).unwrap();
        assert_eq!(n.id, "slack");
        assert_eq!(n.bridge_bot.as_deref(), Some("@slackbot:x"));
        assert_eq!(
            threads_supported_from_features(&json!({"thread": 2})),
            Some(true)
        );
        assert_eq!(
            threads_supported_from_features(&json!({"thread": -1})),
            Some(false)
        );
        assert_eq!(threads_supported_from_features(&json!({"reply": 2})), None);
        let g = guess_network_from_members(["@me:x", "@groupme_123:x"]).unwrap();
        assert_eq!(g.id, "groupme");
    }
}
