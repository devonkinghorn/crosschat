//! Provisioning proxy: `/_crosschat/v1/bridges/{id}/provision/{rest}` →
//! `http://127.0.0.1:{port}/_matrix/provision/{rest}` on the bridge.
//!
//! The caller is authenticated with their Matrix token by crosschatd; the
//! bridge only ever sees crosschatd's shared secret plus `user_id=<caller>`.
//! Any `user_id` the client tries to pass is stripped, so users can't act as
//! each other.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum ProxyError {
    #[error("path not allowed")]
    BadPath,
}

/// Build the upstream URL for a provisioning request.
pub fn upstream_url(
    port: u16,
    rest: &str,
    query: Option<&str>,
    user_id: &str,
) -> Result<String, ProxyError> {
    let rest = rest.trim_start_matches('/');
    let lower = rest.to_ascii_lowercase();
    let segments_ok = rest
        .split('/')
        .all(|s| !s.is_empty() && s != "." && s != "..");
    if !rest.starts_with("v3/")
        || !segments_ok
        || lower.contains("%2e")
        || lower.contains("%2f")
        || rest.contains('\\')
    {
        return Err(ProxyError::BadPath);
    }
    let mut ser = url::form_urlencoded::Serializer::new(String::new());
    if let Some(q) = query {
        for (k, v) in url::form_urlencoded::parse(q.as_bytes()) {
            if k != "user_id" {
                ser.append_pair(&k, &v);
            }
        }
    }
    ser.append_pair("user_id", user_id);
    Ok(format!(
        "http://127.0.0.1:{port}/_matrix/provision/{rest}?{}",
        ser.finish()
    ))
}

/// Identifiers that look like phone numbers or emails are worth resolving
/// directly (`/v3/resolve_identifier`) in addition to a search.
pub fn looks_like_identifier(q: &str) -> bool {
    let q = q.trim();
    let digits = q.chars().filter(|c| c.is_ascii_digit()).count();
    let phone = q.starts_with('+')
        && digits >= 7
        && q.chars()
            .all(|c| c.is_ascii_digit() || " +-().".contains(c));
    let email = q.contains('@') && q.contains('.') && !q.starts_with('@') && !q.contains(' ');
    phone || email
}

/// One contact/search result, tagged with the bridge it came from.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ContactResult {
    pub bridge: String,
    pub network: String,
    pub id: String,
    pub name: Option<String>,
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub identifiers: Vec<String>,
    pub mxid: Option<String>,
    pub dm_room_mxid: Option<String>,
}

/// Convert bridgev2 `ResolvedIdentifier` objects into tagged results.
pub fn tag_results(bridge: &str, network: &str, items: &[Value]) -> Vec<ContactResult> {
    items
        .iter()
        .filter_map(|v| {
            let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
            Some(ContactResult {
                bridge: bridge.to_string(),
                network: network.to_string(),
                id: s("id")?,
                name: s("name"),
                avatar_url: s("avatar_url"),
                identifiers: v
                    .get("identifiers")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(|i| i.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default(),
                mxid: s("mxid"),
                dm_room_mxid: s("dm_room_mxid"),
            })
        })
        .collect()
}

/// Merge results, de-duplicating by (bridge, id).
pub fn merge_results(mut all: Vec<ContactResult>) -> Vec<ContactResult> {
    let mut seen = std::collections::HashSet::new();
    all.retain(|r| seen.insert((r.bridge.clone(), r.id.clone())));
    all
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn builds_url_and_forces_user_id() {
        let u = upstream_url(
            29336,
            "v3/login/flows",
            Some("user_id=%40evil%3Ax&login_id=abc"),
            "@devon:example.com",
        )
        .unwrap();
        assert_eq!(
            u,
            "http://127.0.0.1:29336/_matrix/provision/v3/login/flows?login_id=abc&user_id=%40devon%3Aexample.com"
        );
        let u = upstream_url(1, "/v3/whoami", None, "@a:b").unwrap();
        assert_eq!(
            u,
            "http://127.0.0.1:1/_matrix/provision/v3/whoami?user_id=%40a%3Ab"
        );
    }

    #[test]
    fn rejects_traversal_and_non_v3() {
        for bad in [
            "../admin",
            "v3/../../_matrix/app/v1/transactions",
            "v3/%2e%2e/x",
            "v3/a%2Fb",
            "debug/pprof",
            "v3//x",
            "v3/a\\b",
        ] {
            assert_eq!(
                upstream_url(1, bad, None, "@a:b"),
                Err(ProxyError::BadPath),
                "{bad}"
            );
        }
    }

    #[test]
    fn identifier_detection() {
        assert!(looks_like_identifier("+1 (801) 555-1234"));
        assert!(looks_like_identifier("devon@example.com"));
        assert!(!looks_like_identifier("devon"));
        assert!(!looks_like_identifier("@devon:example.com"));
        assert!(!looks_like_identifier("+12"));
    }

    #[test]
    fn tags_and_merges() {
        let items = vec![
            json!({"id":"u1","name":"Alice","identifiers":["tel:+1555"],"mxid":"@slack_u1:x"}),
            json!({"name":"no id"}),
        ];
        let mut r = tag_results("slack", "slack", &items);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].identifiers, vec!["tel:+1555".to_string()]);
        r.push(r[0].clone());
        assert_eq!(merge_results(r).len(), 1);
    }
}
