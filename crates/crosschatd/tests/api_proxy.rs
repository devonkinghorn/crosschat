//! End-to-end tests of the HTTP API against a fake bridgev2 provisioning
//! server: auth, user_id forcing, routing, status endpoint, search fan-out.

use axum::{
    Json, Router,
    body::Body,
    extract::{Path, RawQuery},
    http::{HeaderMap, Request, StatusCode},
    routing::{get, post},
};
use crosschatd::{
    api,
    auth::{AuthError, TokenValidator},
    bridge::BridgeRuntime,
    config::Config,
    daemon::Daemon,
    manifest::Manifest,
    registration::Tokens,
    secrets::BridgeSecrets,
};
use futures::future::BoxFuture;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct FakeValidator;
impl TokenValidator for FakeValidator {
    fn whoami<'a>(&'a self, token: &'a str) -> BoxFuture<'a, Result<String, AuthError>> {
        Box::pin(async move {
            match token {
                "devon-token" => Ok("@devon:example.com".to_string()),
                "eve-token" => Ok("@eve:evil.org".to_string()),
                _ => Err(AuthError::Invalid),
            }
        })
    }
}

type Seen = Arc<Mutex<Vec<(String, Option<String>, Option<String>)>>>;

/// Fake bridge: records (path, query, auth header) and answers like bridgev2.
async fn fake_bridge(seen: Seen) -> u16 {
    let s1 = seen.clone();
    let s2 = seen.clone();
    let s3 = seen.clone();
    let app = Router::new()
        .route(
            "/_matrix/provision/v3/login/flows",
            get(move |headers: HeaderMap, RawQuery(q): RawQuery| async move {
                s1.lock().unwrap().push((
                    "flows".into(),
                    q,
                    headers.get("authorization").map(|h| h.to_str().unwrap().to_string()),
                ));
                Json(json!({"flows": [{"id": "google", "name": "Google Account", "description": "d"}]}))
            }),
        )
        .route(
            "/_matrix/provision/v3/search_users",
            post(move |RawQuery(q): RawQuery, Json(body): Json<Value>| async move {
                s2.lock().unwrap().push(("search".into(), q, None));
                let query = body["query"].as_str().unwrap_or("").to_string();
                Json(json!({"results": [{"id": "U1", "name": format!("Match for {query}"), "mxid": "@slack_u1:example.com"}]}))
            }),
        )
        .route(
            "/_matrix/provision/v3/resolve_identifier/{ident}",
            get(move |Path(ident): Path<String>| async move {
                s3.lock().unwrap().push(("resolve".into(), Some(ident.clone()), None));
                Json(json!({"id": format!("tel:{ident}"), "name": "Phone contact"}))
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    port
}

fn daemon(port: u16) -> Arc<Daemon> {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let cfg = Config::from_toml(Config::example()).unwrap();
    let manifests = Manifest::load_dir(&root.join("manifests")).unwrap();
    let slack = manifests.iter().find(|m| m.id == "slack").unwrap().clone();
    let rt = Arc::new(BridgeRuntime {
        manifest: slack,
        port,
        data_dir: std::env::temp_dir(),
        secrets: BridgeSecrets {
            tokens: Tokens {
                as_token: "bridge-as-token".into(),
                hs_token: "hs".into(),
            },
            provisioning_secret: "prov-secret".into(),
            pickle_key: "p".into(),
        },
        handle: Mutex::new(None),
        health: Default::default(),
        remote_state: Mutex::new(None),
        setup_error: Mutex::new(None),
        retired: Default::default(),
    });
    let mut bridges = BTreeMap::new();
    bridges.insert("slack".to_string(), rt);
    Arc::new(Daemon::from_parts(
        cfg,
        manifests,
        bridges,
        "admin-secret".into(),
        Arc::new(FakeValidator),
        reqwest::Client::new(),
    ))
}

async fn call(
    d: &Arc<Daemon>,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut req = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let req = match body {
        Some(b) => req
            .header("content-type", "application/json")
            .body(Body::from(b.to_string()))
            .unwrap(),
        None => req.body(Body::empty()).unwrap(),
    };
    let resp = api::router(d.clone()).oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn health_is_public() {
    let d = daemon(1);
    let (s, v) = call(&d, "GET", "/_crosschat/v1/health", None, None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["status"], "ok");
}

#[tokio::test]
async fn provisioning_requires_valid_allowed_token() {
    let seen: Seen = Default::default();
    let d = daemon(fake_bridge(seen.clone()).await);
    let uri = "/_crosschat/v1/bridges/slack/provision/v3/login/flows";
    assert_eq!(
        call(&d, "GET", uri, None, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        call(&d, "GET", uri, Some("garbage"), None).await.0,
        StatusCode::UNAUTHORIZED
    );
    let (s, v) = call(&d, "GET", uri, Some("eve-token"), None).await;
    assert_eq!(s, StatusCode::FORBIDDEN, "{v}");
    assert!(
        seen.lock().unwrap().is_empty(),
        "rejected requests never reach the bridge"
    );
}

#[tokio::test]
async fn provisioning_proxy_forwards_with_shared_secret_and_forced_user() {
    let seen: Seen = Default::default();
    let d = daemon(fake_bridge(seen.clone()).await);
    let (s, v) = call(
        &d,
        "GET",
        "/_crosschat/v1/bridges/slack/provision/v3/login/flows?user_id=@eve:evil.org&x=1",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["flows"][0]["id"], "google");
    let seen = seen.lock().unwrap();
    let (_, q, auth) = &seen[0];
    assert_eq!(q.as_deref(), Some("x=1&user_id=%40devon%3Aexample.com"));
    assert_eq!(auth.as_deref(), Some("Bearer prov-secret"));
}

#[tokio::test]
async fn proxy_rejects_bad_paths_and_unknown_bridges() {
    let d = daemon(1);
    let (s, _) = call(
        &d,
        "GET",
        "/_crosschat/v1/bridges/slack/provision/v3/%2e%2e/x",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _) = call(
        &d,
        "GET",
        "/_crosschat/v1/bridges/whatsapp/provision/v3/whoami",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    // Bridge not listening -> 503, not a hang.
    let (s, v) = call(
        &d,
        "GET",
        "/_crosschat/v1/bridges/slack/provision/v3/whoami",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::SERVICE_UNAVAILABLE, "{v}");
    assert_eq!(v["errcode"], "CC_BRIDGE_UNAVAILABLE");
}

#[tokio::test]
async fn search_fans_out_and_resolves_phone_numbers() {
    let seen: Seen = Default::default();
    let d = daemon(fake_bridge(seen.clone()).await);
    let (s, v) = call(
        &d,
        "POST",
        "/_crosschat/v1/search",
        Some("devon-token"),
        Some(json!({"query": "+18015551234"})),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let results = v["results"].as_array().unwrap();
    assert_eq!(results.len(), 2, "{v}");
    assert!(results.iter().all(|r| r["bridge"] == "slack"));
    assert!(results.iter().any(|r| r["id"] == "tel:+18015551234"));
    let kinds: Vec<String> = seen.lock().unwrap().iter().map(|s| s.0.clone()).collect();
    assert!(kinds.contains(&"search".to_string()) && kinds.contains(&"resolve".to_string()));
}

#[tokio::test]
async fn networks_lists_all_manifests() {
    let d = daemon(1);
    let (s, v) = call(
        &d,
        "GET",
        "/_crosschat/v1/networks",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["admin"], true);
    let bridges = v["bridges"].as_array().unwrap();
    let ids: Vec<&str> = bridges.iter().map(|b| b["id"].as_str().unwrap()).collect();
    assert_eq!(ids, vec!["gmessages", "groupme", "imessage", "slack"]);
    let slack = bridges.iter().find(|b| b["id"] == "slack").unwrap();
    assert_eq!(slack["enabled"], true);
    assert_eq!(slack["capabilities"]["threads"], "yes");
    let imessage = bridges.iter().find(|b| b["id"] == "imessage").unwrap();
    assert_eq!(imessage["enabled"], false);
    assert!(
        imessage["preflight"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["id"] == "contact_key_verification")
    );
}

#[tokio::test]
async fn admin_actions_need_admin() {
    let d = daemon(1);
    // Admin token works for logs even with no process.
    let (s, v) = call(
        &d,
        "GET",
        "/_crosschat/v1/bridges/slack/logs",
        Some("admin-secret"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    // A non-admin local user can't restart bridges.
    let mut cfg_d = d.cfg.clone();
    cfg_d.auth.allow_server_users = true;
    cfg_d.auth.admins.clear();
    let d2 = Arc::new(Daemon::from_parts(
        cfg_d,
        d.manifests.clone(),
        d.bridges.read().unwrap().clone(),
        "admin-secret".into(),
        Arc::new(FakeValidator),
        reqwest::Client::new(),
    ));
    let (s, _) = call(
        &d2,
        "POST",
        "/_crosschat/v1/bridges/slack/restart",
        Some("devon-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn bridge_status_endpoint_checks_as_token() {
    let d = daemon(1);
    let body = json!({"remoteState": {}, "bridgeState": {"state_event": "RUNNING"}});
    let (s, _) = call(
        &d,
        "POST",
        "/_crosschat/internal/bridge-status/slack",
        Some("wrong"),
        Some(body.clone()),
    )
    .await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = call(
        &d,
        "POST",
        "/_crosschat/internal/bridge-status/slack",
        Some("bridge-as-token"),
        Some(body.clone()),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(
        d.bridge("slack")
            .unwrap()
            .remote_state
            .lock()
            .unwrap()
            .as_ref(),
        Some(&body)
    );
}
