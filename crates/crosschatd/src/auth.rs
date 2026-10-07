//! Authenticating app requests with the user's Matrix access token.

use crate::config::AuthConfig;
use futures::future::BoxFuture;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Principal {
    pub user_id: String,
    pub admin: bool,
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum AuthError {
    #[error("missing access token")]
    Missing,
    #[error("invalid access token")]
    Invalid,
    #[error("user {0} is not allowed to use this crosschatd")]
    Forbidden(String),
    #[error("homeserver unreachable: {0}")]
    Upstream(String),
}

pub trait TokenValidator: Send + Sync {
    /// Resolve an access token to an MXID.
    fn whoami<'a>(&'a self, token: &'a str) -> BoxFuture<'a, Result<String, AuthError>>;
}

/// Validates tokens with `GET /_matrix/client/v3/account/whoami`, caching
/// results briefly (keyed by token hash, never the token itself).
pub struct HomeserverValidator {
    http: reqwest::Client,
    hs_url: String,
    ttl: Duration,
    cache: Mutex<HashMap<String, (String, Instant)>>,
}

impl HomeserverValidator {
    pub fn new(http: reqwest::Client, hs_url: &str) -> Self {
        Self { http, hs_url: hs_url.trim_end_matches('/').to_string(), ttl: Duration::from_secs(300), cache: Default::default() }
    }
}

impl TokenValidator for HomeserverValidator {
    fn whoami<'a>(&'a self, token: &'a str) -> BoxFuture<'a, Result<String, AuthError>> {
        Box::pin(async move {
            let key = hex::encode(Sha256::digest(token.as_bytes()));
            if let Some((uid, at)) = self.cache.lock().unwrap().get(&key)
                && at.elapsed() < self.ttl
            {
                return Ok(uid.clone());
            }
            let resp = self
                .http
                .get(format!("{}/_matrix/client/v3/account/whoami", self.hs_url))
                .bearer_auth(token)
                .send()
                .await
                .map_err(|e| AuthError::Upstream(e.to_string()))?;
            if resp.status() == reqwest::StatusCode::UNAUTHORIZED || resp.status() == reqwest::StatusCode::FORBIDDEN {
                return Err(AuthError::Invalid);
            }
            let body: serde_json::Value = resp.json().await.map_err(|e| AuthError::Upstream(e.to_string()))?;
            let uid = body.get("user_id").and_then(|v| v.as_str()).ok_or(AuthError::Invalid)?.to_string();
            self.cache.lock().unwrap().insert(key, (uid.clone(), Instant::now()));
            Ok(uid)
        })
    }
}

/// Decide what a validated user may do.
pub fn authorize(user_id: &str, auth: &AuthConfig, server_name: &str) -> Result<Principal, AuthError> {
    let admin = auth.admins.iter().any(|a| a == user_id);
    // The server part is everything after the *first* colon (it may carry a port).
    let local = user_id.split_once(':').is_some_and(|(_, s)| s == server_name);
    if admin || (auth.allow_server_users && local) {
        Ok(Principal { user_id: user_id.to_string(), admin })
    } else {
        Err(AuthError::Forbidden(user_id.to_string()))
    }
}

/// Constant-time-ish string comparison for shared secrets.
pub fn secret_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn bearer(headers: &axum::http::HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(admins: &[&str], server_users: bool) -> AuthConfig {
        AuthConfig { admins: admins.iter().map(|s| s.to_string()).collect(), allow_server_users: server_users }
    }

    #[test]
    fn admin_and_server_users() {
        let c = cfg(&["@devon:example.com"], false);
        assert_eq!(authorize("@devon:example.com", &c, "example.com").unwrap().admin, true);
        assert!(authorize("@eve:example.com", &c, "example.com").is_err());
        let c = cfg(&["@devon:example.com"], true);
        let p = authorize("@eve:example.com", &c, "example.com").unwrap();
        assert!(!p.admin);
        assert!(authorize("@eve:evil.com", &c, "example.com").is_err());
        assert!(authorize("@eve:evil.com:example.com", &c, "example.com").is_err());
    }

    #[test]
    fn secret_compare() {
        assert!(secret_eq("abc", "abc"));
        assert!(!secret_eq("abc", "abd"));
        assert!(!secret_eq("abc", "abcd"));
    }
}
