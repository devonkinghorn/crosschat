//! HTTP API served by crosschatd under `/_crosschat/` (mount it on the
//! homeserver's domain via the reverse proxy).

use crate::auth::{AuthError, Principal, authorize, bearer, secret_eq};
use crate::bridge::BridgeRuntime;
use crate::daemon::Daemon;
use crate::manifest::{self, Support};
use crate::proxy::{self, ContactResult};
use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{Path, Query, RawQuery, State},
    http::{HeaderMap, Method, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{any, get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

type AppState = Arc<Daemon>;

#[derive(Debug)]
pub struct ApiError(pub StatusCode, pub &'static str, pub String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"errcode": self.1, "error": self.2}))).into_response()
    }
}

impl From<AuthError> for ApiError {
    fn from(e: AuthError) -> Self {
        match e {
            AuthError::Missing => {
                ApiError(StatusCode::UNAUTHORIZED, "M_MISSING_TOKEN", e.to_string())
            }
            AuthError::Invalid => {
                ApiError(StatusCode::UNAUTHORIZED, "M_UNKNOWN_TOKEN", e.to_string())
            }
            AuthError::Forbidden(_) => {
                ApiError(StatusCode::FORBIDDEN, "M_FORBIDDEN", e.to_string())
            }
            AuthError::Upstream(_) => ApiError(
                StatusCode::BAD_GATEWAY,
                "CC_HOMESERVER_UNREACHABLE",
                e.to_string(),
            ),
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/_crosschat/v1/health", get(health))
        .route("/_crosschat/v1/whoami", get(whoami))
        .route("/_crosschat/v1/networks", get(networks))
        .route("/_crosschat/v1/search", post(search))
        .route("/_crosschat/v1/contacts", get(contacts))
        .route("/_crosschat/v1/bridges/{id}/logs", get(logs))
        .route(
            "/_crosschat/v1/bridges/{id}/provision/{*rest}",
            any(provision),
        )
        .route("/_crosschat/v1/bridges/{id}/{action}", post(bridge_action))
        .route(
            "/_crosschat/internal/bridge-status/{id}",
            post(bridge_status),
        )
        .with_state(state)
}

async fn principal(d: &Daemon, headers: &HeaderMap) -> Result<Principal, ApiError> {
    let token = bearer(headers).ok_or(AuthError::Missing)?;
    if secret_eq(token, &d.admin_token) {
        let user_id = d
            .admin_list()
            .first()
            .cloned()
            .unwrap_or_else(|| format!("@crosschatd:{}", d.cfg.homeserver.server_name));
        return Ok(Principal {
            user_id,
            admin: true,
        });
    }
    let uid = d.validator.whoami(token).await?;
    let auth = crate::config::AuthConfig {
        admins: d.admin_list(),
        allow_server_users: d.cfg.auth.allow_server_users,
    };
    Ok(authorize(&uid, &auth, &d.cfg.homeserver.server_name)?)
}

fn require_admin(p: &Principal) -> Result<(), ApiError> {
    if p.admin {
        Ok(())
    } else {
        Err(ApiError(
            StatusCode::FORBIDDEN,
            "M_FORBIDDEN",
            "admin only".into(),
        ))
    }
}

fn find_bridge<'a>(d: &'a Daemon, id: &str) -> Result<&'a Arc<BridgeRuntime>, ApiError> {
    d.bridges.get(id).ok_or_else(|| {
        ApiError(
            StatusCode::NOT_FOUND,
            "M_NOT_FOUND",
            format!("bridge `{id}` is not enabled"),
        )
    })
}

async fn health() -> Json<Value> {
    Json(json!({"status": "ok", "version": env!("CARGO_PKG_VERSION")}))
}

async fn whoami(
    State(d): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Principal>, ApiError> {
    Ok(Json(principal(&d, &headers).await?))
}

async fn networks(State(d): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let p = principal(&d, &headers).await?;
    let host_os = manifest::current_host_os();
    let list: Vec<Value> = d
        .manifests
        .iter()
        .map(|m| {
            let rt = d.bridges.get(&m.id);
            json!({
                "id": m.id,
                "display_name": m.display_name,
                "network": m.network,
                "description": m.description,
                "maturity": m.maturity,
                "license": m.license,
                "homepage": m.homepage,
                "enabled": rt.is_some(),
                "host_supported": m.supports_host(host_os),
                "process": rt.map(|r| serde_json::to_value(r.proc_state()).unwrap()),
                "restarts": rt.and_then(|r| r.handle()).map(|h| h.restarts()),
                "health": rt.map(|r| serde_json::to_value(&*r.health.lock().unwrap()).unwrap()),
                "remote_state": rt.and_then(|r| r.remote_state.lock().unwrap().clone()),
                "setup_error": rt.and_then(|r| r.setup_error.lock().unwrap().clone()),
                "capabilities": m.capabilities,
                "login_flows": m.login.flows,
                "preflight": m.preflight,
                "requirements": m.requirements_for_host(host_os),
            })
        })
        .collect();
    Ok(Json(json!({
        "user_id": p.user_id,
        "admin": p.admin,
        "host_os": host_os,
        "host_platform": manifest::current_platform(),
        "homeserver": d.hs_handle().map(|h| serde_json::to_value(h.state()).unwrap()),
        "bridges": list,
    })))
}

async fn bridge_action(
    State(d): State<AppState>,
    headers: HeaderMap,
    Path((id, action)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_admin(&principal(&d, &headers).await?)?;
    let rt = find_bridge(&d, &id)?;
    let h = rt.handle().ok_or_else(|| {
        ApiError(
            StatusCode::CONFLICT,
            "CC_NOT_INSTALLED",
            "bridge failed setup; see setup_error".into(),
        )
    })?;
    match action.as_str() {
        "start" => h.start(),
        "stop" => h.stop(),
        "restart" => h.restart(),
        _ => {
            return Err(ApiError(
                StatusCode::NOT_FOUND,
                "M_UNRECOGNIZED",
                format!("unknown action `{action}`"),
            ));
        }
    }
    Ok(Json(json!({"ok": true})))
}

#[derive(Deserialize)]
struct LogsQuery {
    lines: Option<usize>,
}

async fn logs(
    State(d): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(q): Query<LogsQuery>,
) -> Result<Json<Value>, ApiError> {
    require_admin(&principal(&d, &headers).await?)?;
    let rt = find_bridge(&d, &id)?;
    let lines = rt
        .handle()
        .map(|h| h.logs(q.lines.unwrap_or(200).min(1000)))
        .unwrap_or_default();
    Ok(Json(json!({"lines": lines})))
}

async fn bridge_status(
    State(d): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let rt = find_bridge(&d, &id)?;
    let ok = bearer(&headers).is_some_and(|t| secret_eq(t, &rt.secrets.tokens.as_token));
    if !ok {
        return Err(ApiError(
            StatusCode::UNAUTHORIZED,
            "M_UNKNOWN_TOKEN",
            "bad bridge token".into(),
        ));
    }
    *rt.remote_state.lock().unwrap() = Some(body);
    Ok(Json(json!({})))
}

async fn provision(
    State(d): State<AppState>,
    method: Method,
    headers: HeaderMap,
    Path((id, rest)): Path<(String, String)>,
    RawQuery(query): RawQuery,
    body: Bytes,
) -> Result<Response, ApiError> {
    let p = principal(&d, &headers).await?;
    let rt = find_bridge(&d, &id)?;
    let url = proxy::upstream_url(rt.port, &rest, query.as_deref(), &p.user_id)
        .map_err(|e| ApiError(StatusCode::BAD_REQUEST, "M_UNRECOGNIZED", e.to_string()))?;
    let mut req = d
        .http
        .request(method, url)
        .bearer_auth(&rt.secrets.provisioning_secret)
        // display_and_wait long-polls until the user scans/taps.
        .timeout(Duration::from_secs(600))
        .body(body.to_vec());
    if let Some(ct) = headers.get(header::CONTENT_TYPE) {
        req = req.header(header::CONTENT_TYPE, ct.clone());
    }
    let resp = req.send().await.map_err(|e| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "CC_BRIDGE_UNAVAILABLE",
            format!("bridge `{id}` unreachable: {e}"),
        )
    })?;
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let ct = resp.headers().get(header::CONTENT_TYPE).cloned();
    let bytes = resp.bytes().await.map_err(|e| {
        ApiError(
            StatusCode::BAD_GATEWAY,
            "CC_BRIDGE_UNAVAILABLE",
            e.to_string(),
        )
    })?;
    let mut out = Response::builder().status(status);
    if let Some(ct) = ct {
        out = out.header(header::CONTENT_TYPE, ct);
    }
    Ok(out.body(Body::from(bytes)).unwrap())
}

#[derive(Deserialize)]
struct SearchBody {
    query: String,
}

async fn call_bridge(
    d: &Daemon,
    rt: &BridgeRuntime,
    method: reqwest::Method,
    rest: &str,
    user: &str,
    body: Option<Value>,
) -> Result<Value, String> {
    let url = proxy::upstream_url(rt.port, rest, None, user).map_err(|e| e.to_string())?;
    let mut req = d
        .http
        .request(method, url)
        .bearer_auth(&rt.secrets.provisioning_secret)
        .timeout(Duration::from_secs(8));
    if let Some(b) = body {
        req = req.json(&b);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let v: Value = resp.json().await.unwrap_or(Value::Null);
    if status.is_success() {
        Ok(v)
    } else {
        Err(v
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| format!("HTTP {status}")))
    }
}

/// Fan a contact search out to every enabled bridge that supports it.
async fn search(
    State(d): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<SearchBody>,
) -> Result<Json<Value>, ApiError> {
    let p = principal(&d, &headers).await?;
    let q = body.query.trim().to_string();
    let futures = d
        .bridges
        .values()
        .filter(|rt| rt.manifest.capabilities.search_users != Support::No)
        .map(|rt| {
            let (d, p, q) = (d.clone(), p.clone(), q.clone());
            async move {
                let mut results: Vec<ContactResult> = Vec::new();
                let mut err = None;
                match call_bridge(
                    &d,
                    rt,
                    reqwest::Method::POST,
                    "v3/search_users",
                    &p.user_id,
                    Some(json!({"query": q})),
                )
                .await
                {
                    Ok(v) => {
                        let items = v
                            .get("results")
                            .and_then(Value::as_array)
                            .cloned()
                            .unwrap_or_default();
                        results.extend(proxy::tag_results(
                            &rt.manifest.id,
                            &rt.manifest.network,
                            &items,
                        ));
                    }
                    Err(e) => err = Some(e),
                }
                if proxy::looks_like_identifier(&q) {
                    let path = format!(
                        "v3/resolve_identifier/{}",
                        url::form_urlencoded::byte_serialize(q.as_bytes()).collect::<String>()
                    );
                    if let Ok(v) =
                        call_bridge(&d, rt, reqwest::Method::GET, &path, &p.user_id, None).await
                    {
                        results.extend(proxy::tag_results(
                            &rt.manifest.id,
                            &rt.manifest.network,
                            &[v],
                        ));
                    }
                }
                (rt.manifest.id.clone(), results, err)
            }
        });
    let mut all = Vec::new();
    let mut errors = BTreeMap::new();
    for (id, results, err) in futures::future::join_all(futures).await {
        all.extend(results);
        if let Some(e) = err {
            errors.insert(id, e);
        }
    }
    Ok(Json(
        json!({"results": proxy::merge_results(all), "errors": errors}),
    ))
}

#[derive(Deserialize)]
struct ContactsQuery {
    bridge: String,
}

async fn contacts(
    State(d): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<ContactsQuery>,
) -> Result<Json<Value>, ApiError> {
    let p = principal(&d, &headers).await?;
    let rt = find_bridge(&d, &q.bridge)?;
    let v = call_bridge(
        &d,
        rt,
        reqwest::Method::GET,
        "v3/contacts",
        &p.user_id,
        None,
    )
    .await
    .map_err(|e| ApiError(StatusCode::BAD_GATEWAY, "CC_BRIDGE_ERROR", e))?;
    let items = v
        .get("contacts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(Json(
        json!({"contacts": proxy::tag_results(&rt.manifest.id, &rt.manifest.network, &items)}),
    ))
}
