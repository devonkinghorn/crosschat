//! Pure helpers for message content beyond plain text: attachments,
//! reactions, SMS/RCS tapback fallbacks, sender names and read state.
//! Kept free of matrix-sdk types so they can be unit-tested on raw JSON.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// An attachment. `source` is the JSON the SDK needs to fetch it:
/// `{"url": "mxc://…"}` or, in encrypted rooms, `{"file": {…}}`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaInfo {
    pub source: String,
    pub mimetype: Option<String>,
    pub size: Option<u64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    /// File name (`filename`, else `body`).
    pub filename: String,
    /// Text sent with the attachment (`body` when `filename` differs).
    pub caption: Option<String>,
    /// Server-side thumbnail, same JSON shape as `source`.
    pub thumbnail_source: Option<String>,
}

/// Reactions with one key on one message.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reaction {
    pub key: String,
    /// MXIDs, oldest first.
    pub senders: Vec<String>,
    /// The user reacted with this key.
    pub own: bool,
}

/// A tapback sent as text by SMS / RCS fallback, e.g. iPhone's
/// `Loved “see you soon”` / `Laughed at an image`, or Google Messages'
/// `\u{200b}👍\u{200b} to “see you soon”`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tapback {
    /// Reaction emoji.
    pub key: String,
    /// "Removed a heart from …".
    pub removed: bool,
    /// The quoted text, without quotes (and without a trailing ellipsis).
    pub target_text: Option<String>,
    /// Whether the quote was cut short ("…" at the end).
    pub truncated: bool,
    /// For "an image" / "a video" / …: `image`, `video`, `audio`, `file`,
    /// or `any` ("a message").
    pub target_kind: Option<String>,
}

fn str_of<'a>(v: Option<&'a Value>, key: &str) -> Option<&'a str> {
    v?.get(key)?.as_str()
}

fn source_json(content: &Value, url_key: &str, file_key: &str) -> Option<String> {
    if let Some(file) = content.get(file_key).filter(|f| f.is_object()) {
        return Some(serde_json::json!({ "file": file }).to_string());
    }
    let url = content.get(url_key)?.as_str()?;
    url.starts_with("mxc://")
        .then(|| serde_json::json!({ "url": url }).to_string())
}

/// Attachment info of an `m.image` / `m.video` / `m.audio` / `m.file` /
/// `m.sticker` content.
pub fn parse_media(content: &Value) -> Option<MediaInfo> {
    let source = source_json(content, "url", "file")?;
    let info = content.get("info");
    let body = content.get("body").and_then(Value::as_str).unwrap_or("");
    let filename = content
        .get("filename")
        .and_then(Value::as_str)
        .filter(|f| !f.is_empty());
    let (filename, caption) = match filename {
        Some(f) if f != body && !body.is_empty() => (f.to_owned(), Some(body.to_owned())),
        Some(f) => (f.to_owned(), None),
        None => (body.to_owned(), None),
    };
    let num = |k: &str| info.and_then(|i| i.get(k)).and_then(Value::as_u64);
    Some(MediaInfo {
        source,
        mimetype: str_of(info, "mimetype").map(str::to_owned),
        size: num("size"),
        width: num("w").map(|v| v as u32),
        height: num("h").map(|v| v as u32),
        duration_ms: num("duration"),
        filename,
        caption,
        thumbnail_source: info.and_then(|i| source_json(i, "thumbnail_url", "thumbnail_file")),
    })
}

/// `m.annotation` reactions in a batch of raw events, by target event id.
/// Redacted reactions (empty content) are skipped.
pub fn collect_reactions(raw_events: &[Value], own_user: &str) -> HashMap<String, Vec<Reaction>> {
    let mut out: HashMap<String, Vec<Reaction>> = HashMap::new();
    for ev in raw_events {
        if ev.get("type").and_then(Value::as_str) != Some("m.reaction") {
            continue;
        }
        let Some(rel) = ev.get("content").and_then(|c| c.get("m.relates_to")) else {
            continue;
        };
        if rel.get("rel_type").and_then(Value::as_str) != Some("m.annotation") {
            continue;
        }
        let (Some(target), Some(key), Some(sender)) = (
            rel.get("event_id").and_then(Value::as_str),
            rel.get("key").and_then(Value::as_str),
            ev.get("sender").and_then(Value::as_str),
        ) else {
            continue;
        };
        add_reaction(
            out.entry(target.to_owned()).or_default(),
            key,
            sender,
            own_user,
        );
    }
    out
}

/// Add one reaction to a message's groups (deduplicated per sender + key).
pub fn add_reaction(groups: &mut Vec<Reaction>, key: &str, sender: &str, own_user: &str) {
    let key = normalize_key(key);
    let group = match groups.iter().position(|g| g.key == key) {
        Some(i) => &mut groups[i],
        None => {
            groups.push(Reaction {
                key: key.clone(),
                ..Default::default()
            });
            groups.last_mut().unwrap()
        }
    };
    if !group.senders.iter().any(|s| s == sender) {
        group.senders.push(sender.to_owned());
    }
    group.own |= sender == own_user;
}

/// Reaction keys differ only in emoji variation selectors between networks
/// ("👍" vs "👍️"); group them as one.
pub fn normalize_key(key: &str) -> String {
    key.trim().trim_end_matches('\u{fe0f}').to_owned()
}

const ZWSP: char = '\u{200b}';

/// iPhone tapback verbs (classic set) and their emoji.
const TAPBACK_VERBS: &[(&str, &str)] = &[
    ("Loved", "❤️"),
    ("Liked", "👍"),
    ("Disliked", "👎"),
    ("Laughed at", "😂"),
    ("Emphasized", "‼️"),
    ("Questioned", "❓"),
];

/// "Removed a heart from …" nouns.
const TAPBACK_REMOVED: &[(&str, &str)] = &[
    ("a heart", "❤️"),
    ("a like", "👍"),
    ("a dislike", "👎"),
    ("a laugh", "😂"),
    ("an exclamation", "‼️"),
    ("an exclamation mark", "‼️"),
    ("a question mark", "❓"),
];

/// "… an image" targets and the attachment kind they refer to.
const TAPBACK_TARGETS: &[(&str, &str)] = &[
    ("an image", "image"),
    ("a photo", "image"),
    ("a picture", "image"),
    ("a gif", "image"),
    ("a sticker", "image"),
    ("a video", "video"),
    ("a movie", "video"),
    ("an audio message", "audio"),
    ("a voice message", "audio"),
    ("an attachment", "file"),
    ("a file", "file"),
    ("a contact", "file"),
    ("a location", "file"),
    ("a message", "any"),
];

fn is_reaction_key(s: &str) -> bool {
    let n = s.chars().count();
    (1..=12).contains(&n) && !s.chars().any(|c| c.is_alphanumeric() || c.is_whitespace())
}

/// The target of a tapback: `“quoted text”` or a noun like `an image`.
/// Anything else means the text wasn't a tapback.
fn tapback_target(rest: &str, key: String, removed: bool) -> Option<Tapback> {
    let rest = rest.trim();
    let quotes = [('“', '”'), ('"', '"'), ('‘', '’')];
    for (open, close) in quotes {
        if let Some(inner) = rest.strip_prefix(open).and_then(|r| r.strip_suffix(close)) {
            let inner = inner.trim();
            let (text, truncated) = match inner
                .strip_suffix('…')
                .or_else(|| inner.strip_suffix("..."))
            {
                Some(t) => (t.trim_end(), true),
                None => (inner, false),
            };
            if text.is_empty() {
                return None;
            }
            return Some(Tapback {
                key,
                removed,
                target_text: Some(text.to_owned()),
                truncated,
                target_kind: None,
            });
        }
    }
    let lower = rest.to_lowercase();
    let lower = lower.trim_end_matches('.');
    TAPBACK_TARGETS
        .iter()
        .find(|(noun, _)| *noun == lower)
        .map(|(_, kind)| Tapback {
            key,
            removed,
            target_text: None,
            truncated: false,
            target_kind: Some((*kind).to_owned()),
        })
}

/// Recognise SMS/RCS tapback fallback texts. Returns `None` for ordinary
/// messages (including ones that merely start with "Loved").
pub fn parse_tapback(body: &str) -> Option<Tapback> {
    let body = body.trim();
    // Google Messages: "\u200b👍\u200b to “…”".
    if let Some(after) = body.strip_prefix(ZWSP) {
        let (key, rest) = after.split_once(ZWSP)?;
        let rest = rest.strip_prefix(" to ")?;
        if !is_reaction_key(key.trim()) {
            return None;
        }
        return tapback_target(rest, key.trim().to_owned(), false);
    }
    // iOS 18+: "Reacted 🎉 to “…”" / "Removed 🎉 from “…”".
    for (prefix, sep, removed) in [("Reacted ", " to ", false), ("Removed ", " from ", true)] {
        if let Some(after) = body.strip_prefix(prefix)
            && let Some((key, rest)) = after.split_once(sep)
            && is_reaction_key(key.trim())
        {
            return tapback_target(rest, key.trim().to_owned(), removed);
        }
    }
    // "Removed a heart from “…”".
    if let Some(after) = body.strip_prefix("Removed ") {
        for (noun, key) in TAPBACK_REMOVED {
            if let Some(rest) = after
                .strip_prefix(noun)
                .and_then(|r| r.strip_prefix(" from "))
            {
                return tapback_target(rest, (*key).to_owned(), true);
            }
        }
        return None;
    }
    // Classic iPhone: "Loved “…”", "Laughed at an image".
    for (verb, key) in TAPBACK_VERBS {
        if let Some(rest) = body.strip_prefix(verb).and_then(|r| r.strip_prefix(' ')) {
            return tapback_target(rest, (*key).to_owned(), false);
        }
    }
    None
}

/// Localpart prefixes of the ghost users of bridges Crosschat runs.
const GHOST_PREFIXES: &[&str] = &[
    "gmessages_",
    "imessage_",
    "imessagego_",
    "slack_",
    "groupme_",
    "whatsapp_",
    "signal_",
    "telegram_",
    "discord_",
    "meta_",
    "instagram_",
    "facebook_",
    "googlechat_",
    "linkedin_",
    "twitter_",
    "bluesky_",
];

fn localpart(user_id: &str) -> &str {
    user_id
        .trim_start_matches('@')
        .split(':')
        .next()
        .unwrap_or("")
}

/// A bridge puppet ("ghost") of a remote contact.
pub fn is_ghost(user_id: &str) -> bool {
    let lp = localpart(user_id);
    GHOST_PREFIXES.iter().any(|p| lp.starts_with(p))
}

/// A name for a user without a usable display name: the localpart for
/// Matrix users; for bridge ghosts the remote id when it reads like a phone
/// number, else "Unknown contact" (ghost ids like `gmessages_1.14` mean
/// nothing to people). Never a raw MXID.
pub fn fallback_name(user_id: &str) -> String {
    let lp = localpart(user_id);
    if let Some(rest) = GHOST_PREFIXES.iter().find_map(|p| lp.strip_prefix(p)) {
        // mautrix escapes '+' as "=2b"; iMessage ids look like "tel-+1555…".
        let rest = rest.replace("=2b", "+").replace("=2B", "+");
        let rest = rest
            .strip_prefix("tel")
            .map(|r| r.trim_start_matches(['-', '_', ':']))
            .unwrap_or(&rest);
        let digits: String = rest.chars().filter(char::is_ascii_digit).collect();
        let phone = digits.len() >= 7
            && rest
                .chars()
                .all(|c| c.is_ascii_digit() || matches!(c, '+' | '-' | '.' | ' '));
        return if phone {
            format!("+{digits}")
        } else {
            "Unknown contact".to_owned()
        };
    }
    if lp.is_empty() {
        "Unknown".to_owned()
    } else {
        lp.to_owned()
    }
}

/// The name to show for a sender: the room display name; when two members
/// share it, Matrix users get their MXID appended (bridge ghosts don't: their
/// MXIDs are meaningless). Falls back to [`fallback_name`].
pub fn display_name_for(user_id: &str, display_name: Option<&str>, ambiguous: bool) -> String {
    let name = display_name
        .map(str::trim)
        .filter(|n| !n.is_empty() && *n != user_id && !(n.starts_with('@') && n.contains(':')));
    match name {
        Some(n) if ambiguous && !is_ghost(user_id) => format!("{n} ({user_id})"),
        Some(n) => n.to_owned(),
        None => fallback_name(user_id),
    }
}

/// Whether a room is marked unread, from its `m.marked_unread` and
/// `com.famedly.marked_unread` account data contents (stable wins).
pub fn marked_unread(stable: Option<&Value>, unstable: Option<&Value>) -> bool {
    let flag = |v: Option<&Value>| v.and_then(|c| c.get("unread")).and_then(Value::as_bool);
    flag(stable).or_else(|| flag(unstable)).unwrap_or(false)
}

/// Which event to put the read receipt on, given a room's latest events
/// newest first: the newest message-like event (bridges map those to the
/// remote network), else the newest event of any kind.
pub fn pick_read_target(newest_first: &[Value]) -> Option<String> {
    let id = |e: &Value| e.get("event_id").and_then(Value::as_str).map(str::to_owned);
    newest_first
        .iter()
        .find(|e| {
            matches!(
                e.get("type").and_then(Value::as_str),
                Some("m.room.message" | "m.room.encrypted" | "m.sticker")
            ) && e.get("state_key").is_none()
        })
        .and_then(id)
        .or_else(|| newest_first.iter().find_map(id))
}

/// Room-list preview of a message.
pub fn preview(msg: &crate::model::Message) -> String {
    if let Some(t) = &msg.tapback {
        let what = match (&t.target_text, t.target_kind.as_deref()) {
            (Some(text), _) => format!("“{text}”"),
            (None, Some("image")) => "an image".into(),
            (None, Some("video")) => "a video".into(),
            (None, Some("audio")) => "an audio message".into(),
            (None, Some("file")) => "an attachment".into(),
            _ => "a message".into(),
        };
        return if t.removed {
            format!("Removed {} from {what}", t.key)
        } else {
            format!("Reacted {} to {what}", t.key)
        };
    }
    if let Some(m) = &msg.media {
        if let Some(c) = m.caption.as_deref().filter(|c| !c.is_empty()) {
            return c.to_owned();
        }
        let kind = match msg.kind {
            crate::model::MessageKind::Image => "Photo",
            crate::model::MessageKind::Video => "Video",
            crate::model::MessageKind::Audio => "Audio",
            crate::model::MessageKind::Sticker => "Sticker",
            _ => "File",
        };
        return if m.filename.is_empty() {
            kind.to_owned()
        } else {
            format!("{kind}: {}", m.filename)
        };
    }
    msg.body.clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{MessageKind, build_main_timeline, parse_event};
    use serde_json::json;

    /// Synthetic events with the exact shapes mautrix-gmessages / -slack
    /// produce on a real install (encrypted `file` media without
    /// thumbnails, `.heic` names with `image/jpeg`, text-only tapbacks).
    fn fixture() -> Vec<Value> {
        serde_json::from_str(include_str!("../fixtures/gmessages_events.json")).unwrap()
    }

    const ME: &str = "@devon:localhost";

    fn by_id<'a>(msgs: &'a [crate::model::Message], id: &str) -> &'a crate::model::Message {
        msgs.iter().find(|m| m.event_id == id).unwrap()
    }

    #[test]
    fn encrypted_media_is_parsed_not_shown_as_filename() {
        let tl = build_main_timeline(&fixture(), ME);
        let img = by_id(&tl, "$img1");
        assert_eq!(img.kind, MessageKind::Image);
        assert_eq!(img.body, "", "the file name is not message text");
        let m = img.media.as_ref().unwrap();
        assert_eq!(m.filename, "IMG_3406.heic");
        assert_eq!(m.mimetype.as_deref(), Some("image/jpeg"));
        let src: Value = serde_json::from_str(&m.source).unwrap();
        assert_eq!(src["file"]["url"], "mxc://localhost/heicasjpeg");
        assert_eq!(src["file"]["v"], "v2");
        assert!(m.thumbnail_source.is_none());

        let gif = by_id(&tl, "$gif1").media.clone().unwrap();
        assert_eq!(gif.filename, "funny.gif");
        assert_eq!(gif.mimetype.as_deref(), Some("image/gif"));
        assert!(gif.caption.is_none());

        let heic = by_id(&tl, "$heic1");
        let hm = heic.media.as_ref().unwrap();
        assert_eq!(hm.filename, "IMG_0001.heic");
        assert_eq!(hm.caption.as_deref(), Some("look at this"));
        assert_eq!(heic.body, "look at this");
        assert_eq!((hm.width, hm.height), (Some(4284), Some(5712)));

        let vid = by_id(&tl, "$vid1");
        assert_eq!(vid.kind, MessageKind::Video);
        assert_eq!(vid.media.as_ref().unwrap().size, Some(16205603));
        assert_eq!(
            by_id(&tl, "$pdf1").media.as_ref().unwrap().filename,
            "menu.pdf"
        );
    }

    #[test]
    fn plain_media_url_and_thumbnail() {
        let ev = json!({"type":"m.room.message","event_id":"$p","sender":"@a:x","origin_server_ts":1,
            "content":{"msgtype":"m.image","body":"cat.png","url":"mxc://x/cat",
              "info":{"mimetype":"image/png","w":640,"h":480,"thumbnail_url":"mxc://x/thumb"}}});
        let m = parse_event(&ev, ME).unwrap().media.unwrap();
        assert_eq!(m.source, r#"{"url":"mxc://x/cat"}"#);
        assert_eq!(
            m.thumbnail_source.as_deref(),
            Some(r#"{"url":"mxc://x/thumb"}"#)
        );
    }

    #[test]
    fn real_reactions_are_grouped_on_their_target() {
        let tl = build_main_timeline(&fixture(), ME);
        let t1 = by_id(&tl, "$t1");
        // "👍️" (with VS16, from the bridge) and "👍" are one group.
        assert_eq!(t1.reactions.len(), 1);
        assert_eq!(t1.reactions[0].key, "👍");
        assert_eq!(t1.reactions[0].senders.len(), 2);
        assert!(t1.reactions[0].own);
        assert!(
            tl.iter().all(|m| m.event_id != "$r1"),
            "reactions aren't messages"
        );
    }

    #[test]
    fn sms_tapback_fallbacks_are_recognised() {
        let tl = build_main_timeline(&fixture(), ME);
        let t = |id: &str| by_id(&tl, id).tapback.clone();
        let laugh = t("$tb1").unwrap();
        assert_eq!(laugh.key, "😂");
        assert_eq!(laugh.target_kind.as_deref(), Some("image"));
        let love = t("$tb2").unwrap();
        assert_eq!(love.key, "❤️");
        assert_eq!(love.target_text.as_deref(), Some("Dinner at 7 on Sunday?"));
        let google = t("$tb3").unwrap();
        assert_eq!(google.key, "👍");
        assert_eq!(
            google.target_text.as_deref(),
            Some("Dinner at 7 on Sunday?")
        );
        assert_eq!(t("$tb4").unwrap().key, "‼️");
        assert_eq!(t("$tb5").unwrap().key, "📚");
        assert!(t("$t2").is_none(), "ordinary text starting with a verb");
        assert!(t("$t1").is_none());
    }

    #[test]
    fn tapback_variants() {
        let r = parse_tapback("Removed a heart from “ok”").unwrap();
        assert!(r.removed);
        assert_eq!(r.key, "❤️");
        let q = parse_tapback("Questioned “this is a very long message that got cut…”").unwrap();
        assert!(q.truncated);
        assert_eq!(
            q.target_text.as_deref(),
            Some("this is a very long message that got cut")
        );
        assert_eq!(
            parse_tapback("Liked a video")
                .unwrap()
                .target_kind
                .as_deref(),
            Some("video")
        );
        assert_eq!(
            parse_tapback("Liked \"plain quotes\"")
                .unwrap()
                .target_text
                .as_deref(),
            Some("plain quotes")
        );
        assert!(parse_tapback("Liked it").is_none());
        assert!(parse_tapback("Reacted to the news").is_none());
        assert!(parse_tapback("\u{200b}hello\u{200b} to “x”").is_none());
    }

    #[test]
    fn ghost_names_never_show_mxids() {
        assert_eq!(
            display_name_for("@gmessages_1.14:localhost", Some("Alex Rivera"), false),
            "Alex Rivera"
        );
        // No display name yet: never the raw MXID.
        assert_eq!(
            fallback_name("@gmessages_1.14:localhost"),
            "Unknown contact"
        );
        assert_eq!(
            display_name_for("@gmessages_1.14:localhost", None, false),
            "Unknown contact"
        );
        assert_eq!(
            display_name_for(
                "@gmessages_1.14:localhost",
                Some("@gmessages_1.14:localhost"),
                false
            ),
            "Unknown contact"
        );
        assert_eq!(
            fallback_name("@imessage_tel=2b15551234567:localhost"),
            "+15551234567"
        );
        assert_eq!(fallback_name("@alice:example.org"), "alice");
        // Duplicate names: Matrix users get disambiguated, ghosts don't.
        assert_eq!(
            display_name_for("@sam:x", Some("Sam"), true),
            "Sam (@sam:x)"
        );
        assert_eq!(
            display_name_for("@gmessages_1.9:x", Some("Sam"), true),
            "Sam"
        );
        // Fresh messages (the live sync path) start from the fallback, not the MXID.
        let ev = &fixture()[2];
        assert_eq!(parse_event(ev, ME).unwrap().sender_name, "Unknown contact");
    }

    #[test]
    fn marked_unread_stable_and_unstable() {
        assert!(!marked_unread(None, None));
        assert!(marked_unread(None, Some(&json!({"unread": true}))));
        assert!(!marked_unread(
            Some(&json!({"unread": false})),
            Some(&json!({"unread": true}))
        ));
        assert!(marked_unread(Some(&json!({"unread": true})), None));
    }

    #[test]
    fn read_target_is_newest_message() {
        let mut newest_first = fixture();
        newest_first.reverse();
        assert_eq!(pick_read_target(&newest_first).as_deref(), Some("$t2"));
        let only_reaction = vec![json!({"type":"m.reaction","event_id":"$r"})];
        assert_eq!(pick_read_target(&only_reaction).as_deref(), Some("$r"));
        let encrypted = vec![
            json!({"type":"m.reaction","event_id":"$r"}),
            json!({"type":"m.room.encrypted","event_id":"$e"}),
        ];
        assert_eq!(pick_read_target(&encrypted).as_deref(), Some("$e"));
        assert_eq!(pick_read_target(&[]), None);
    }

    #[test]
    fn previews() {
        let tl = build_main_timeline(&fixture(), ME);
        assert_eq!(preview(by_id(&tl, "$img1")), "Photo: IMG_3406.heic");
        assert_eq!(preview(by_id(&tl, "$tb1")), "Reacted 😂 to an image");
        assert_eq!(preview(by_id(&tl, "$heic1")), "look at this");
    }
}
