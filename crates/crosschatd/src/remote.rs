//! Access from other devices (local mode, `[remote_access]`).
//!
//! The local server binds 127.0.0.1 only. A phone reaches it through the
//! user's own TLS reverse proxy, which forwards to a second listener here
//! (`0.0.0.0:8008` by default). That listener serves:
//!
//! * `/_matrix/client/**` and `/_matrix/media/**`: streamed to the bundled
//!   homeserver (bodies and long-polling `/sync` pass straight through);
//! * `/.well-known/matrix/client`: `base_url` = the public URL (so a client
//!   can sign in with just the domain);
//! * `/_crosschat/v1/**`: crosschatd's API (networks, bridge logins,
//!   contact search), authenticated with the caller's Matrix token, except
//!   the local-only `/_crosschat/v1/local/**`.
//!
//! Everything else (federation, appservice and admin endpoints, the bridge
//! status hook) answers 404. Bridges and their appservice ports, Tuwunel
//! itself and crosschatd's main listener stay on loopback. `server_name`
//! stays `localhost`: clients only need the URL.

use crate::config::{Config, RemoteAccessConfig};
use crate::local::LocalServer;
use axum::Router;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderName, StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::get;
use serde::Serialize;
use serde_json::{Value, json};
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use tower::ServiceExt;
use tracing::{info, warn};

/// The running listener and the settings it was started with.
#[derive(Default)]
pub struct Runtime {
    pub cfg: RemoteAccessConfig,
    pub listening: Option<SocketAddr>,
    pub error: Option<String>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl Runtime {
    pub fn new(cfg: RemoteAccessConfig) -> Self {
        Self {
            cfg,
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct LanAddress {
    pub interface: String,
    pub address: IpAddr,
}

/// IPv4 addresses of this computer's network interfaces (no loopback or
/// link-local), for "point your proxy at …".
pub fn lan_addresses() -> Vec<LanAddress> {
    let mut out = Vec::new();
    #[cfg(unix)]
    unsafe {
        let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut cur = head;
        while !cur.is_null() {
            let ifa = &*cur;
            cur = ifa.ifa_next;
            if ifa.ifa_addr.is_null() || i32::from((*ifa.ifa_addr).sa_family) != libc::AF_INET {
                continue;
            }
            let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
            let ip = std::net::Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
            if ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() {
                continue;
            }
            let name = std::ffi::CStr::from_ptr(ifa.ifa_name)
                .to_string_lossy()
                .into_owned();
            let entry = LanAddress {
                interface: name,
                address: IpAddr::V4(ip),
            };
            if !out.contains(&entry) {
                out.push(entry);
            }
        }
        libc::freeifaddrs(head);
    }
    // Private (LAN) addresses first.
    out.sort_by_key(|a| match a.address {
        IpAddr::V4(v4) => !v4.is_private(),
        IpAddr::V6(_) => true,
    });
    out
}

/// This computer's host name (on a Mac, `Name.local` also works on the LAN).
pub fn hostname() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
        if rc == 0 {
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            let h = String::from_utf8_lossy(&buf[..end]).into_owned();
            if !h.is_empty() {
                return Some(h);
            }
        }
    }
    None
}

/// Start, restart or stop the listener to match `cfg`. Errors (port in
/// use, …) are kept in `rt.error` and returned.
pub async fn apply(local: &Arc<LocalServer>, rt: &mut Runtime, cfg: RemoteAccessConfig) {
    if let Some(t) = rt.task.take() {
        // Drop open connections (long-polling syncs) right away; clients retry.
        t.abort();
        let _ = t.await;
        info!("stopped listening for other devices");
    }
    rt.listening = None;
    rt.error = None;
    rt.cfg = cfg.clone();
    if !cfg.enabled {
        return;
    }
    let addr = SocketAddr::new(cfg.address, cfg.port);
    match tokio::net::TcpListener::bind(addr).await {
        Ok(listener) => {
            let bound = listener.local_addr().unwrap_or(addr);
            let app = lan_router(local.clone());
            rt.task = Some(tokio::spawn(async move {
                if let Err(e) = axum::serve(listener, app).await {
                    warn!("remote access listener stopped: {e}");
                }
            }));
            rt.listening = Some(bound);
            info!("listening for other devices on http://{bound} (Matrix client API only)");
        }
        Err(e) => {
            let msg = if e.kind() == std::io::ErrorKind::AddrInUse {
                format!(
                    "Port {} is already in use on this computer. Pick another port.",
                    cfg.port
                )
            } else {
                format!("Couldn't listen on {addr}: {e}")
            };
            warn!("{msg}");
            rt.error = Some(msg);
        }
    }
}

/// `GET /_crosschat/v1/local/remote-access` body.
pub fn status_json(cfg: &Config, rt: &Runtime) -> Value {
    let addrs = lan_addresses();
    let port = rt.cfg.port;
    let host = hostname();
    let proxy_targets: Vec<String> = match rt.cfg.address {
        IpAddr::V4(a) if a.is_unspecified() => addrs
            .iter()
            .map(|a| format!("http://{}:{port}", a.address))
            .chain(
                host.iter()
                    .filter(|h| h.ends_with(".local"))
                    .map(|h| format!("http://{h}:{port}")),
            )
            .collect(),
        a => vec![format!("http://{a}:{port}")],
    };
    json!({
        "enabled": rt.cfg.enabled,
        "address": rt.cfg.address,
        "port": port,
        "public_url": rt.cfg.public_url,
        "listening": rt.listening.map(|a| a.to_string()),
        "error": rt.error,
        "lan_addresses": addrs,
        "hostname": host,
        "proxy_targets": proxy_targets,
        "server_name": cfg.homeserver.server_name,
    })
}

pub fn lan_router(local: Arc<LocalServer>) -> Router {
    Router::new()
        .route("/.well-known/matrix/client", get(well_known))
        .fallback(lan_fallback)
        .with_state(local)
}

fn not_found() -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(json!({"errcode": "M_UNRECOGNIZED", "error": "Not available from other devices"})),
    )
        .into_response()
}

/// The URL clients should use: the public URL, else what they used to get here.
fn base_url(local: &LocalServer, headers: &HeaderMap) -> String {
    if let Some(u) = local.remote_public_url() {
        return u.trim_end_matches('/').to_string();
    }
    let proto = headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .filter(|p| matches!(*p, "http" | "https"))
        .unwrap_or("http");
    let host = headers
        .get("x-forwarded-host")
        .or_else(|| headers.get(header::HOST))
        .and_then(|v| v.to_str().ok())
        .unwrap_or("localhost");
    format!("{proto}://{host}")
}

async fn well_known(State(l): State<Arc<LocalServer>>, headers: HeaderMap) -> Response {
    (
        [(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")],
        Json(json!({"m.homeserver": {"base_url": base_url(&l, &headers)}})),
    )
        .into_response()
}

/// Which listener-side route a path belongs to.
#[derive(Debug, PartialEq)]
pub enum Route {
    Homeserver,
    Crosschat,
    Denied,
}

pub fn classify(path: &str) -> Route {
    // No dot segments or encoded separators: the upstream must see exactly
    // the path we checked.
    let lower = path.to_ascii_lowercase();
    if path.split('/').any(|s| s == "." || s == "..")
        || lower.contains("%2e")
        || lower.contains("%2f")
        || lower.contains('\\')
    {
        return Route::Denied;
    }
    if path.starts_with("/_matrix/client/") || path.starts_with("/_matrix/media/") {
        Route::Homeserver
    } else if path.starts_with("/_crosschat/v1/") && !path.starts_with("/_crosschat/v1/local/") {
        Route::Crosschat
    } else {
        Route::Denied
    }
}

async fn lan_fallback(State(l): State<Arc<LocalServer>>, req: Request) -> Response {
    match classify(req.uri().path()) {
        Route::Denied => not_found(),
        Route::Crosschat => match l.api_router() {
            Some(api) => match api.oneshot(req).await {
                Ok(r) => r,
                Err(e) => match e {},
            },
            None => (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"errcode": "CC_STARTING", "error": "The server is starting"})),
            )
                .into_response(),
        },
        Route::Homeserver => forward(&l, req).await,
    }
}

const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
];

fn hop_by_hop(name: &HeaderName) -> bool {
    HOP_BY_HOP.contains(&name.as_str())
}

/// Stream a request to the homeserver and its response back.
async fn forward(l: &LocalServer, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let pq = parts
        .uri
        .path_and_query()
        .map(|p| p.as_str())
        .unwrap_or("/");
    let url = format!("{}{}", l.cfg.homeserver.url.trim_end_matches('/'), pq);
    let mut rb = l.proxy_http.request(parts.method.clone(), url);
    for (k, v) in &parts.headers {
        if !hop_by_hop(k) && k != header::HOST {
            rb = rb.header(k, v);
        }
    }
    let rb = rb.body(reqwest::Body::wrap_stream(body.into_data_stream()));
    let resp = match rb.send().await {
        Ok(r) => r,
        Err(e) => {
            warn!("forwarding to the homeserver failed: {e}");
            return (
                StatusCode::BAD_GATEWAY,
                Json(json!({"errcode": "CC_HOMESERVER_UNREACHABLE", "error": "The Matrix server on this computer isn't answering"})),
            )
                .into_response();
        }
    };
    let mut out = Response::builder().status(resp.status());
    for (k, v) in resp.headers() {
        if !hop_by_hop(k) {
            out = out.header(k, v);
        }
    }
    out.body(Body::from_stream(resp.bytes_stream()))
        .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_client_api_and_crosschat_user_api_are_exposed() {
        assert_eq!(classify("/_matrix/client/v3/sync"), Route::Homeserver);
        assert_eq!(classify("/_matrix/client/versions"), Route::Homeserver);
        assert_eq!(classify("/_matrix/media/v3/upload"), Route::Homeserver);
        assert_eq!(classify("/_crosschat/v1/networks"), Route::Crosschat);
        for denied in [
            "/_matrix/federation/v1/version",
            "/_matrix/key/v2/server",
            "/_matrix/app/v1/transactions/1",
            "/_crosschat/v1/local/owner",
            "/_crosschat/v1/local/remote-access",
            "/_crosschat/internal/bridge-status/slack",
            "/_matrix/client/../federation/v1/version",
            "/_matrix/client/%2e%2e/federation/v1/version",
            "/_matrix/client%2F..%2Ffederation",
            "/_crosschat/v1/../v1/local/owner",
            "/_synapse/admin/v1/users",
            "/",
        ] {
            assert_eq!(classify(denied), Route::Denied, "{denied}");
        }
    }

    #[test]
    fn lan_addresses_skip_loopback() {
        assert!(lan_addresses().iter().all(|a| !a.address.is_loopback()));
    }
}
