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
