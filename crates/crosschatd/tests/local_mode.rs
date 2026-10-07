//! Local mode HTTP API: status while starting, owner bootstrap through a
//! fake homeserver's user-interactive registration, and routing to the
//! regular API once ready.

use axum::{
    Json, Router,
    body::Body,
    http::{Request, StatusCode},
    routing::post,
};
use crosschatd::auth::{AuthError, TokenValidator};
use crosschatd::daemon::Daemon;
use crosschatd::local::{self, LocalOptions, LocalPaths, LocalServer, LocalState};
use crosschatd::secrets::Vault;
use futures::future::BoxFuture;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

struct OwnerValidator;
impl TokenValidator for OwnerValidator {
    fn whoami<'a>(&'a self, token: &'a str) -> BoxFuture<'a, Result<String, AuthError>> {
        Box::pin(async move {
            match token {
                "owner-token" => Ok("@devon:localhost".into()),
                _ => Err(AuthError::Invalid),
            }
        })
    }
}

/// Fake homeserver `/register`: registration-token UIA stage, then success.
async fn fake_hs(token: &'static str, seen: Arc<Mutex<Vec<Value>>>) -> String {
    let app = Router::new().route(
        "/_matrix/client/v3/register",
        post(move |Json(body): Json<Value>| {
            let seen = seen.clone();
            async move {
                seen.lock().unwrap().push(body.clone());
                let user = body["username"].as_str().unwrap_or("").to_string();
                if user == "taken" {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(
                            json!({"errcode": "M_USER_IN_USE", "error": "User ID already taken."}),
                        ),
                    );
                }
                let auth = &body["auth"];
                let ok = auth["type"] == "m.login.registration_token"
                    && auth["token"] == token
                    && auth["session"] == "S1";
                if ok {
                    (
                        StatusCode::OK,
                        Json(json!({"user_id": format!("@{user}:localhost")})),
                    )
                } else {
                    (
                        StatusCode::UNAUTHORIZED,
                        Json(json!({
                            "session": "S1",
                            "flows": [{"stages": ["m.login.registration_token"]}],
                            "params": {},
                        })),
                    )
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://127.0.0.1:{port}")
}

async fn call(
    app: &Router,
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
    let resp = app.clone().oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

struct Fixture {
    _dir: tempfile::TempDir,
    paths: LocalPaths,
    local: Arc<LocalServer>,
    app: Router,
    seen: Arc<Mutex<Vec<Value>>>,
}

async fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let paths = LocalPaths::new(dir.path().join("server"));
    let opts = LocalOptions {
        bridges: vec![],
        ..Default::default()
    };
    let mut cfg = local::prepare(&paths, &opts).unwrap();
    // Seed the vault's registration token the way Daemon::setup would.
    let token = {
        let mut v = Vault::open(cfg.data_dir.join("vault.json")).unwrap();
        v.hs_registration_token().unwrap()
    };
    let token: &'static str = Box::leak(token.into_boxed_str());
    let seen = Arc::new(Mutex::new(Vec::new()));
    cfg.homeserver.url = fake_hs(token, seen.clone()).await;
    let local = LocalServer::new(paths.clone(), cfg).unwrap();
    let app = local::router(local.clone());
    Fixture {
        _dir: dir,
        paths,
        local,
        app,
        seen,
    }
}

fn ready(f: &Fixture) {
    let d = Daemon::from_parts(
        f.local.cfg.clone(),
        vec![],
        BTreeMap::new(),
        f.local.admin_token.clone(),
        Arc::new(OwnerValidator),
        reqwest::Client::new(),
    );
    f.local.set_ready(Arc::new(d));
}

#[tokio::test]
async fn status_while_starting_and_api_is_503() {
    let f = fixture().await;
    let (s, v) = call(&f.app, "GET", "/_crosschat/v1/local/status", None, None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["mode"], "local");
    assert_eq!(v["phase"], "starting");
    assert_eq!(v["server_name"], "localhost");
    assert_eq!(v["federation"], false);
    assert_eq!(v["daemon_url"], "http://127.0.0.1:29300");
    assert_eq!(v["owner"], Value::Null);
    assert_eq!(v["data_dir"], f.paths.root.display().to_string());
    let (s, v) = call(&f.app, "GET", "/_crosschat/v1/health", None, None).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["phase"], "starting");
    let (s, v) = call(&f.app, "GET", "/_crosschat/v1/networks", Some("x"), None).await;
    assert_eq!(s, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(v["errcode"], "CC_STARTING");
    // The admin token was written for the app to read.
    let written = std::fs::read_to_string(f.paths.data().join("admin.token")).unwrap();
    assert_eq!(written, f.local.admin_token);
    // Owner creation must wait for the homeserver.
    let (s, v) = call(
        &f.app,
        "POST",
        "/_crosschat/v1/local/owner",
        Some(&f.local.admin_token.clone()),
        Some(json!({"username": "devon", "password": "correct horse"})),
    )
    .await;
    assert_eq!(s, StatusCode::SERVICE_UNAVAILABLE, "{v}");
    f.local.set_failed("boom".into());
    let (_, v) = call(&f.app, "GET", "/_crosschat/v1/local/status", None, None).await;
    assert_eq!(v["phase"], "failed");
    assert_eq!(v["error"], "boom");
}

#[tokio::test]
async fn owner_bootstrap_registers_once_and_becomes_admin() {
    let f = fixture().await;
    ready(&f);
    let admin = f.local.admin_token.clone();
    let owner = |token: Option<&str>, user: &str, pass: &str| {
        let app = f.app.clone();
        let token = token.map(str::to_owned);
        let body = json!({"username": user, "password": pass});
        async move {
            call(
                &app,
                "POST",
                "/_crosschat/v1/local/owner",
                token.as_deref(),
                Some(body),
            )
            .await
        }
    };

    // Needs the local admin token.
    let (s, _) = owner(None, "devon", "correct horse").await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = owner(Some("nope"), "devon", "correct horse").await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // Validation happens before touching the homeserver.
    let (s, v) = owner(Some(&admin), "Devon Kinghorn", "correct horse").await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["errcode"], "M_INVALID_USERNAME");
    let (s, v) = owner(Some(&admin), "devon", "short").await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert_eq!(v["errcode"], "M_WEAK_PASSWORD");
    assert!(f.seen.lock().unwrap().is_empty());
    // Taken usernames surface as 409.
    let (s, v) = owner(Some(&admin), "taken", "correct horse").await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["errcode"], "M_USER_IN_USE");

    // Happy path: "@Devon" is normalized, UIA with the vault token.
    let (s, v) = owner(Some(&admin), "@Devon", "correct horse").await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["user_id"], "@devon:localhost");
    {
        let seen = f.seen.lock().unwrap();
        let last = seen.last().unwrap();
        assert_eq!(last["username"], "devon");
        assert_eq!(last["inhibit_login"], true);
        assert_eq!(last["auth"]["type"], "m.login.registration_token");
    }
    let state = LocalState::load(&f.paths.state()).unwrap();
    assert_eq!(state.owner.as_deref(), Some("@devon:localhost"));
    let (_, v) = call(&f.app, "GET", "/_crosschat/v1/local/status", None, None).await;
    assert_eq!(v["owner"], "@devon:localhost");
    assert_eq!(v["phase"], "ready");

    // Only once.
    let (s, v) = owner(Some(&admin), "mallory", "correct horse").await;
    assert_eq!(s, StatusCode::CONFLICT);
    assert_eq!(v["errcode"], "CC_OWNER_EXISTS");

    // The regular API is routed through, and the owner is an admin.
    let (s, v) = call(
        &f.app,
        "GET",
        "/_crosschat/v1/whoami",
        Some("owner-token"),
        None,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["user_id"], "@devon:localhost");
    assert_eq!(v["admin"], true);

    // A restart picks the owner up from local.json.
    let cfg = local::prepare(
        &f.paths,
        &LocalOptions {
            bridges: vec![],
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(cfg.auth.admins, vec!["@devon:localhost".to_string()]);
}

#[tokio::test]
async fn wrong_registration_token_is_reported() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let hs = fake_hs("right", seen.clone()).await;
    let err = local::register_with_token(
        &reqwest::Client::new(),
        &hs,
        "wrong",
        "devon",
        "correct horse",
    )
    .await
    .unwrap_err();
    assert_eq!(err.1, "CC_REGISTER_FAILED");
    assert!(err.2.contains("registration token"), "{}", err.2);
    assert_eq!(seen.lock().unwrap().len(), 2);
}
