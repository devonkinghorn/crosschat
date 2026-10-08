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
        .route("/_crosschat/v1/resolve", post(resolve))
        .route("/_crosschat/v1/dm", post(start_dm))
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

fn find_bridge(d: &Daemon, id: &str) -> Result<Arc<BridgeRuntime>, ApiError> {
    d.bridge(id).ok_or_else(|| {
        ApiError(
            StatusCode::NOT_FOUND,
            "M_NOT_FOUND",
            format!("bridge `{id}` is not enabled"),
        )
    })
}

fn internal(e: anyhow::Error) -> ApiError {
    ApiError(
        StatusCode::INTERNAL_SERVER_ERROR,
        "CC_INTERNAL",
        format!("{e:#}"),
    )
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
            let rt = d.bridge(&m.id);
            let rt = rt.as_ref();
            let progress = d.progress_of(&m.id);
            let setup_error = rt
                .and_then(|r| r.setup_error.lock().unwrap().clone())
                .or_else(|| d.enable_errors.lock().unwrap().get(&m.id).cloned());
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
                "setup_error": setup_error,
                // Enabling right now: what it's doing ("Installing iMessage").
                "progress": progress,
                "keep_awake": m.keep_awake,
                "identifier_prefixes": m.identifier_prefixes,
                "host_platforms": m.host_platforms,
                "capabilities": m.capabilities,
                "login_flows": m.login.flows,
                "preflight": m.preflight_for_host(host_os),
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
        "keeping_awake": d.keeping_awake(),
        // Whether this daemon can turn bridges on and off ("Add network").
        "can_manage": true,
        "bridges": list,
    })))
}

async fn bridge_action(
    State(d): State<AppState>,
    headers: HeaderMap,
    Path((id, action)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_admin(&principal(&d, &headers).await?)?;
    match action.as_str() {
        "enable" => {
            if d.manifest(&id).is_none() {
                return Err(ApiError(
                    StatusCode::NOT_FOUND,
                    "M_NOT_FOUND",
                    format!("no bridge called `{id}`"),
                ));
            }
            // Downloads and a homeserver restart can take a while: run in the
            // background; GET /networks shows `progress` and `setup_error`.
            let d2 = d.clone();
            let id2 = id.clone();
            tokio::spawn(async move {
                let _ = d2.enable(&id2).await;
            });
            return Ok(Json(json!({"ok": true, "started": true})));
        }
        "disable" => {
            d.disable(&id).await.map_err(internal)?;
            return Ok(Json(json!({"ok": true})));
        }
        "remove" => {
            d.remove(&id).await.map_err(internal)?;
            return Ok(Json(json!({"ok": true})));
        }
        _ => {}
    }
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

#[derive(Deserialize)]
struct ResolveBody {
    /// A phone number or email, in any common format.
    identifier: String,
    /// Only ask these bridges (default: every running one).
    #[serde(default)]
    bridges: Option<Vec<String>>,
}

fn encode_path(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// Is this phone number / email reachable on each network? Asks every
/// running bridge's `resolve_identifier` (in the form that bridge expects,
/// e.g. `tel:+15551234567` for iMessage). `results[bridge]` is the contact,
/// or null when the network says it isn't reachable there.
async fn resolve(
    State(d): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<ResolveBody>,
) -> Result<Json<Value>, ApiError> {
    let p = principal(&d, &headers).await?;
    let bridges: Vec<_> = d
        .bridge_list()
        .into_iter()
        .filter(|rt| {
            body.bridges
                .as_ref()
                .is_none_or(|only| only.iter().any(|b| b == &rt.manifest.id))
        })
        .collect();
    let futures = bridges.iter().map(|rt| {
        let (d, p) = (d.clone(), p.clone());
        let ident = rt.manifest.network_identifier(&body.identifier);
        async move {
            let path = format!("v3/resolve_identifier/{}", encode_path(&ident));
            let r = call_bridge(&d, rt, reqwest::Method::GET, &path, &p.user_id, None).await;
            (
                rt.manifest.id.clone(),
                rt.manifest.network.clone(),
                ident,
                r,
            )
        }
    });
    let mut results = serde_json::Map::new();
    let mut errors = serde_json::Map::new();
    for (id, network, ident, r) in futures::future::join_all(futures).await {
        match r {
            Ok(v) => {
                let mut tagged = proxy::tag_results(&id, &network, &[v]);
                let mut c = serde_json::to_value(tagged.remove(0)).unwrap_or(Value::Null);
                if c["identifiers"].as_array().is_none_or(|a| a.is_empty()) {
                    c["identifiers"] = json!([ident]);
                }
                results.insert(id, c);
            }
            Err(e) => {
                results.insert(id.clone(), Value::Null);
                errors.insert(id, json!(e));
            }
        }
    }
    Ok(Json(json!({"results": results, "errors": errors})))
}

#[derive(Deserialize)]
struct DmBody {
    bridge: String,
    /// A phone number or email (normalized for the bridge), or the bridge's
    /// own user id from search results.
    identifier: String,
    #[serde(default)]
    login_id: Option<String>,
}

/// Create (or reuse) a DM with someone on one network; returns the bridge's
/// `create_dm` response (`dm_room_mxid`, ...).
async fn start_dm(
    State(d): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<DmBody>,
) -> Result<Json<Value>, ApiError> {
    let p = principal(&d, &headers).await?;
    let rt = find_bridge(&d, &body.bridge)?;
    let ident = rt.manifest.network_identifier(&body.identifier);
    let mut path = format!("v3/create_dm/{}", encode_path(&ident));
    if let Some(l) = &body.login_id {
        path.push_str(&format!("?login_id={}", encode_path(l)));
    }
    let v = call_bridge(
        &d,
        &rt,
        reqwest::Method::POST,
        &path,
        &p.user_id,
        Some(json!({})),
    )
    .await
    .map_err(|e| ApiError(StatusCode::BAD_GATEWAY, "CC_BRIDGE_ERROR", e))?;
    Ok(Json(v))
}

async fn call_bridge(
    d: &Daemon,
    rt: &BridgeRuntime,
    method: reqwest::Method,
    rest: &str,
    user: &str,
    body: Option<Value>,
) -> Result<Value, String> {
    let (rest, query) = match rest.split_once('?') {
        Some((r, q)) => (r, Some(q)),
        None => (rest, None),
    };
    let url = proxy::upstream_url(rt.port, rest, query, user).map_err(|e| e.to_string())?;
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
    let bridges = d.bridge_list();
    // search_users where the bridge has it; resolve_identifier (is this
    // phone number / email on the network?) everywhere for identifier queries.
    let futures = bridges
        .iter()
        .filter(|rt| {
            rt.manifest.capabilities.search_users != Support::No || proxy::looks_like_identifier(&q)
        })
        .map(|rt| {
            let (d, p, q) = (d.clone(), p.clone(), q.clone());
            async move {
                let mut results: Vec<ContactResult> = Vec::new();
                let mut err = None;
                let searched = if rt.manifest.capabilities.search_users == Support::No {
                    Ok(json!({"results": []}))
                } else {
                    call_bridge(
                        &d,
                        rt,
                        reqwest::Method::POST,
                        "v3/search_users",
                        &p.user_id,
                        Some(json!({"query": q})),
                    )
                    .await
                };
                match searched {
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
                    let ident = rt.manifest.network_identifier(&q);
                    let path = format!(
                        "v3/resolve_identifier/{}",
                        url::form_urlencoded::byte_serialize(ident.as_bytes()).collect::<String>()
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
        &rt,
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
