//! End-to-end smoke test against a real homeserver.
//!
//! Skipped unless `CROSSCHAT_SMOKE_HS`, `CROSSCHAT_SMOKE_USER` and
//! `CROSSCHAT_SMOKE_PASSWORD` are set. `scripts/smoke.sh` starts a bundled
//! Tuwunel through crosschatd, registers a user and runs this.

use crosschat_core::{CoreEvent, CrosschatClient, probe_homeserver};
use std::time::Duration;

fn env() -> Option<(String, String, String)> {
    Some((
        std::env::var("CROSSCHAT_SMOKE_HS").ok()?,
        std::env::var("CROSSCHAT_SMOKE_USER").ok()?,
        std::env::var("CROSSCHAT_SMOKE_PASSWORD").ok()?,
    ))
}

#[tokio::test]
async fn login_send_thread_sync_restore() {
    let Some((hs, user, password)) = env() else {
        eprintln!("skipping: CROSSCHAT_SMOKE_* not set");
        return;
    };
    let versions = probe_homeserver(&hs).await.expect("homeserver reachable");
    assert!(!versions.is_empty());

    let dir = tempfile::tempdir().unwrap();
    let client = CrosschatClient::login(&hs, &user, &password, dir.path(), "crosschat smoke")
        .await
        .expect("login");
    assert!(client.user_id().starts_with('@'));
    assert!(client.access_token().is_some());

    let room = client
        .create_group("Smoke room", &[])
        .await
        .expect("create room");
    client.sync_once().await.unwrap();

    let root = client
        .send_text(&room, "hello from **crosschat**", None)
        .await
        .expect("send");
    let reply = client
        .send_text(&room, "first thread reply", Some(&root))
        .await
        .expect("thread reply");
    let reply2 = client
        .send_text(&room, "second thread reply", Some(&root))
        .await
        .expect("thread reply 2");
    client.sync_once().await.unwrap();

    let tl = client.timeline(&room, 50).await.expect("timeline");
    let root_msg = tl
        .iter()
        .find(|m| m.event_id == root)
        .expect("root in main timeline");
    assert_eq!(root_msg.body, "hello from **crosschat**");
    assert!(root_msg.is_own);
    let summary = root_msg.thread.as_ref().expect("thread summary on root");
    assert_eq!(summary.reply_count, 2, "{summary:?}");
    assert_eq!(
        summary.latest_reply_body.as_deref(),
        Some("second thread reply")
    );
    assert!(
        tl.iter()
            .all(|m| m.event_id != reply && m.event_id != reply2),
        "thread replies hidden from channel"
    );

    let thread = client.thread(&room, &root, 50).await.expect("thread");
    let ids: Vec<&str> = thread.iter().map(|m| m.event_id.as_str()).collect();
    assert_eq!(
        ids,
        vec![root.as_str(), reply.as_str(), reply2.as_str()],
        "{thread:?}"
    );
    assert_eq!(thread[1].thread_root.as_deref(), Some(root.as_str()));

    let rooms = client.rooms().await.unwrap();
    let r = rooms
        .iter()
        .find(|r| r.room_id == room)
        .expect("room listed");
    assert_eq!(r.name, "Smoke room");
    assert_eq!(r.last_message.as_deref(), Some("hello from **crosschat**"));
    assert!(r.network.is_none());

    // Live sync delivers new messages as events.
    let mut events = client.subscribe();
    client.start_sync();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let live = client.send_text(&room, "live message", None).await.unwrap();
    let got = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let Ok(CoreEvent::NewMessage { message, .. }) = events.recv().await
                && message.event_id == live
            {
                return message;
            }
        }
    })
    .await
    .expect("live message via sync");
    assert_eq!(got.body, "live message");
    client.stop_sync();

    // Session restore from disk.
    let user_id = client.user_id();
    drop(client);
    let restored = CrosschatClient::restore(dir.path())
        .await
        .unwrap()
        .expect("stored session");
    assert_eq!(restored.user_id(), user_id);
    restored
        .sync_once()
        .await
        .expect("restored session can sync");
    let tl = restored.timeline(&room, 10).await.unwrap();
    assert!(tl.iter().any(|m| m.event_id == live));
    restored.logout().await.unwrap();
    assert!(
        CrosschatClient::restore(dir.path())
            .await
            .unwrap()
            .is_none()
    );
}

/// Read state against a real homeserver: opening a chat (mark_read) clears
/// the server's unread count, and the marked-unread flag round-trips.
/// Needs a second account (`CROSSCHAT_SMOKE_USER2` / `_PASSWORD2`).
#[tokio::test]
async fn read_receipts_clear_unread_and_marked_unread_round_trips() {
    let Some((hs, user, password)) = env() else {
        eprintln!("skipping: CROSSCHAT_SMOKE_* not set");
        return;
    };
    let (Ok(user2), Ok(password2)) = (
        std::env::var("CROSSCHAT_SMOKE_USER2"),
        std::env::var("CROSSCHAT_SMOKE_PASSWORD2"),
    ) else {
        eprintln!("skipping: CROSSCHAT_SMOKE_USER2 not set");
        return;
    };
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let alice = CrosschatClient::login(&hs, &user, &password, da.path(), "smoke a")
        .await
        .unwrap();
    let bob = CrosschatClient::login(&hs, &user2, &password2, db.path(), "smoke b")
        .await
        .unwrap();
    let room = alice
        .create_group("Read state", &[bob.user_id()])
        .await
        .unwrap();
    bob.sync_once().await.unwrap();
    bob.join(&room).await.unwrap();
    alice.sync_once().await.unwrap();
    alice.send_text(&room, "one", None).await.unwrap();
    let last = alice.send_text(&room, "two", None).await.unwrap();

    let unread = |c: &CrosschatClient| {
        let c = c.clone();
        let room = room.clone();
        async move {
            c.sync_once().await.unwrap();
            let r = c.rooms().await.unwrap();
            let r = r.iter().find(|r| r.room_id == room).unwrap();
            (r.unread, r.marked_unread)
        }
    };
    let (n, marked) = unread(&bob).await;
    assert!(n >= 2, "server counts the new messages as unread: {n}");
    assert!(!marked);

    // Opening the chat: receipt + fully_read on the latest message.
    let marked_id = bob.mark_read(&room, None).await.unwrap();
    assert_eq!(marked_id.as_deref(), Some(last.as_str()));
    assert_eq!(
        unread(&bob).await,
        (0, false),
        "unread cleared by the receipt"
    );
    // Same receipt again is a no-op (not re-sent).
    assert_eq!(
        bob.mark_read(&room, None).await.unwrap().as_deref(),
        Some(last.as_str())
    );

    // Mark as unread / read.
    bob.set_marked_unread(&room, true).await.unwrap();
    assert_eq!(unread(&bob).await, (0, true));
    bob.mark_read(&room, None).await.unwrap();
    assert_eq!(unread(&bob).await, (0, false));

    // New message after reading counts again.
    alice.send_text(&room, "three", None).await.unwrap();
    let (n, _) = unread(&bob).await;
    assert_eq!(n, 1);
}

#[tokio::test]
async fn global_account_data_follows_the_account_to_other_devices() {
    let Some((hs, user, password)) = env() else {
        eprintln!("skipping: CROSSCHAT_SMOKE_* not set");
        return;
    };
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = CrosschatClient::login(&hs, &user, &password, da.path(), "smoke prefs a")
        .await
        .unwrap();
    let ty = "app.crosschat.contact_networks";
    let prefs = serde_json::json!({"version": 1, "by_contact": {"tel:+15550000001": "imessage"}, "rooms": {}});
    a.set_global_account_data(ty, &prefs).await.unwrap();
    // A fresh device has nothing cached: read from the server.
    let b = CrosschatClient::login(&hs, &user, &password, db.path(), "smoke prefs b")
        .await
        .unwrap();
    assert_eq!(
        b.global_account_data(ty).await.unwrap(),
        Some(prefs.clone())
    );
    assert_eq!(
        b.global_account_data("app.crosschat.unset").await.unwrap(),
        None
    );
}

#[tokio::test]
async fn reactions_send_annotations_and_redact_to_remove() {
    let Some((hs, user, password)) = env() else {
        eprintln!("skipping: CROSSCHAT_SMOKE_* not set");
        return;
    };
    let (Ok(user2), Ok(password2)) = (
        std::env::var("CROSSCHAT_SMOKE_USER2"),
        std::env::var("CROSSCHAT_SMOKE_PASSWORD2"),
    ) else {
        eprintln!("skipping: CROSSCHAT_SMOKE_USER2 not set");
        return;
    };
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let alice = CrosschatClient::login(&hs, &user, &password, da.path(), "smoke react a")
        .await
        .unwrap();
    let bob = CrosschatClient::login(&hs, &user2, &password2, db.path(), "smoke react b")
        .await
        .unwrap();
    let room = alice
        .create_group("Reactions", &[bob.user_id()])
        .await
        .unwrap();
    bob.sync_once().await.unwrap();
    bob.join(&room).await.unwrap();
    alice.sync_once().await.unwrap();
    let msg = alice.send_text(&room, "react to me", None).await.unwrap();
    bob.sync_once().await.unwrap();

    let reactions = |c: &CrosschatClient, target: String| {
        let c = c.clone();
        let room = room.clone();
        async move {
            c.sync_once().await.unwrap();
            let tl = c.timeline(&room, 50).await.unwrap();
            let m = tl.into_iter().find(|m| m.event_id == target).unwrap();
            m.reactions
                .into_iter()
                .map(|r| (r.key, r.senders.len(), r.own))
                .collect::<Vec<_>>()
        }
    };

    assert!(bob.set_reaction(&room, &msg, "👍", true).await.unwrap());
    assert!(
        !bob.set_reaction(&room, &msg, "👍", true).await.unwrap(),
        "adding twice is a no-op"
    );
    assert_eq!(
        reactions(&bob, msg.clone()).await,
        vec![("👍".into(), 1, true)]
    );
    assert_eq!(
        reactions(&alice, msg.clone()).await,
        vec![("👍".into(), 1, false)]
    );

    // Same emoji with a variation selector groups with it.
    assert!(
        alice
            .set_reaction(&room, &msg, "👍\u{fe0f}", true)
            .await
            .unwrap()
    );
    assert!(alice.set_reaction(&room, &msg, "✅", true).await.unwrap());
    assert_eq!(
        reactions(&alice, msg.clone()).await,
        vec![("👍".into(), 2, true), ("✅".into(), 1, true)]
    );

    // Removing redacts only the user's own reaction.
    assert!(bob.set_reaction(&room, &msg, "👍", false).await.unwrap());
    assert!(!bob.set_reaction(&room, &msg, "👍", false).await.unwrap());
    assert_eq!(
        reactions(&bob, msg.clone()).await,
        vec![("👍".into(), 1, false), ("✅".into(), 1, false)]
    );
    assert!(alice.set_reaction(&room, &msg, "👍", false).await.unwrap());
    assert_eq!(
        reactions(&alice, msg.clone()).await,
        vec![("✅".into(), 1, true)]
    );

    // Thread replies show their reactions in the thread view, and a single
    // message (the Saved list) carries its reactions too.
    let reply = alice
        .send_text(&room, "in a thread", Some(&msg))
        .await
        .unwrap();
    bob.sync_once().await.unwrap();
    assert!(bob.set_reaction(&room, &reply, "👀", true).await.unwrap());
    alice.sync_once().await.unwrap();
    let thread = alice.thread(&room, &msg, 50).await.unwrap();
    let r = thread.iter().find(|m| m.event_id == reply).unwrap();
    assert_eq!(r.reactions.len(), 1);
    assert_eq!(r.reactions[0].key, "👀");
    assert!(!r.reactions[0].own);
    let one = alice.message(&room, &msg).await.unwrap().expect("message");
    assert_eq!(one.body, "react to me");
    assert_eq!(one.reactions.len(), 1);
    assert_eq!(one.reactions[0].key, "✅");
    assert!(one.reactions[0].own);
}

#[tokio::test]
async fn reactions_work_in_encrypted_rooms() {
    use matrix_sdk::ruma::{
        api::client::room::create_room::v3::Request as CreateRoom,
        events::{InitialStateEvent, room::encryption::RoomEncryptionEventContent},
    };
    let Some((hs, user, password)) = env() else {
        eprintln!("skipping: CROSSCHAT_SMOKE_* not set");
        return;
    };
    let (Ok(user2), Ok(password2)) = (
        std::env::var("CROSSCHAT_SMOKE_USER2"),
        std::env::var("CROSSCHAT_SMOKE_PASSWORD2"),
    ) else {
        eprintln!("skipping: CROSSCHAT_SMOKE_USER2 not set");
        return;
    };
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let alice = CrosschatClient::login(&hs, &user, &password, da.path(), "smoke e2ee a")
        .await
        .unwrap();
    let bob = CrosschatClient::login(&hs, &user2, &password2, db.path(), "smoke e2ee b")
        .await
        .unwrap();
    alice.sync_once().await.unwrap();
    bob.sync_once().await.unwrap();
    let mut req = CreateRoom::new();
    req.name = Some("Encrypted reactions".into());
    req.invite = vec![bob.user_id().parse().unwrap()];
    req.initial_state = vec![
        InitialStateEvent::with_empty_state_key(
            RoomEncryptionEventContent::with_recommended_defaults(),
        )
        .to_raw_any(),
    ];
    let room = alice
        .sdk()
        .create_room(req)
        .await
        .unwrap()
        .room_id()
        .to_string();
    bob.sync_once().await.unwrap();
    bob.join(&room).await.unwrap();
    alice.sync_once().await.unwrap();
    bob.sync_once().await.unwrap();
    let msg = alice.send_text(&room, "secret", None).await.unwrap();
    bob.sync_once().await.unwrap();

    assert!(bob.set_reaction(&room, &msg, "❤️", true).await.unwrap());
    bob.sync_once().await.unwrap();
    assert!(
        !bob.set_reaction(&room, &msg, "❤", true).await.unwrap(),
        "own encrypted reaction found through relations"
    );
    alice.sync_once().await.unwrap();
    let tl = alice.timeline(&room, 50).await.unwrap();
    let m = tl.iter().find(|m| m.event_id == msg).unwrap();
    assert_eq!(m.reactions.len(), 1, "alice decrypts bob's reaction");
    assert_eq!(m.reactions[0].senders, vec![bob.user_id()]);

    assert!(bob.set_reaction(&room, &msg, "❤️", false).await.unwrap());
    alice.sync_once().await.unwrap();
    let tl = alice.timeline(&room, 50).await.unwrap();
    let m = tl.iter().find(|m| m.event_id == msg).unwrap();
    assert!(
        m.reactions.is_empty(),
        "redaction removed it: {:?}",
        m.reactions
    );
}
