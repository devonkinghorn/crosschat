//! Appservice registration generation.
//!
//! crosschatd generates the registration itself (instead of running the
//! bridge with `-g`) so tokens live in the crosschatd vault and the same
//! registration can be handed to any homeserver provider.

use crate::manifest::Manifest;
use rand::RngCore;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Namespace {
    pub exclusive: bool,
    pub regex: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Namespaces {
    #[serde(default)]
    pub users: Vec<Namespace>,
    #[serde(default)]
    pub aliases: Vec<Namespace>,
    #[serde(default)]
    pub rooms: Vec<Namespace>,
}

/// Synapse-compatible registration YAML (also read by Tuwunel's
/// `appservice_dir` and Continuwuity's `!admin appservices register`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Registration {
    pub id: String,
    /// `None` = no URL (used for the double-puppet appservice).
    pub url: Option<String>,
    pub as_token: String,
    pub hs_token: String,
    pub sender_localpart: String,
    pub rate_limited: bool,
    pub namespaces: Namespaces,
    #[serde(rename = "de.sorunome.msc2409.push_ephemeral", default, skip_serializing_if = "std::ops::Not::not")]
    pub push_ephemeral: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub receive_ephemeral: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tokens {
    pub as_token: String,
    pub hs_token: String,
}

/// 256-bit random token, hex encoded.
pub fn random_token() -> String {
    let mut buf = [0u8; 32];
    rand::rng().fill_bytes(&mut buf);
    hex::encode(buf)
}

impl Tokens {
    pub fn generate() -> Self {
        Self { as_token: random_token(), hs_token: random_token() }
    }
}

/// Escape a server name for use inside a regex.
pub fn server_name_regex(server_name: &str) -> String {
    regex::escape(server_name)
}

/// Regex matching the MXIDs of a bridge's ghosts, derived from its Go
/// `username_template` (`prefix{{.}}suffix`).
pub fn ghost_regex(username_template: &str, server_name: &str) -> String {
    let (pre, suf) = username_template.split_once("{{.}}").unwrap_or((username_template, ""));
    format!("^@{}.+{}:{}$", regex::escape(pre), regex::escape(suf), server_name_regex(server_name))
}

pub fn generate(manifest: &Manifest, server_name: &str, url: &str, tokens: &Tokens) -> Registration {
    let r = &manifest.registration;
    Registration {
        id: manifest.id.clone(),
        url: Some(url.to_string()),
        as_token: tokens.as_token.clone(),
        hs_token: tokens.hs_token.clone(),
        sender_localpart: r.bot_username.clone(),
        rate_limited: false,
        namespaces: Namespaces {
            users: vec![
                Namespace {
                    exclusive: true,
                    regex: format!("^@{}:{}$", regex::escape(&r.bot_username), server_name_regex(server_name)),
                },
                Namespace { exclusive: true, regex: ghost_regex(&r.username_template, server_name) },
            ],
            ..Default::default()
        },
        push_ephemeral: r.ephemeral_events,
        receive_ephemeral: r.ephemeral_events,
    }
}

/// The double-puppet appservice: no URL, non-exclusive namespace over all
/// local users, so bridges can act as the real user (`as_token:` secret).
/// This token can impersonate every local user: it never leaves the host.
pub fn double_puppet(server_name: &str, as_token: &str) -> Registration {
    Registration {
        id: "crosschat-doublepuppet".into(),
        url: None,
        as_token: as_token.to_string(),
        hs_token: random_token(),
        sender_localpart: format!("crosschat-dp-{}", &random_token()[..8]),
        rate_limited: false,
        namespaces: Namespaces {
            users: vec![Namespace { exclusive: false, regex: format!("@.*:{}", server_name_regex(server_name)) }],
            ..Default::default()
        },
        push_ephemeral: false,
        receive_ephemeral: false,
    }
}

impl Registration {
    pub fn to_yaml(&self) -> String {
        serde_yaml_ng::to_string(self).expect("registration serializes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;
    use regex::Regex;

    fn manifest() -> Manifest {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../manifests/gmessages.yaml");
        Manifest::load(&dir).unwrap()
    }

    #[test]
    fn tokens_are_random_and_long() {
        let a = Tokens::generate();
        let b = Tokens::generate();
        assert_eq!(a.as_token.len(), 64);
        assert_ne!(a.as_token, a.hs_token);
        assert_ne!(a.as_token, b.as_token);
    }

    #[test]
    fn registration_namespaces_match_expected_users() {
        let reg = generate(&manifest(), "example.com", "http://127.0.0.1:29336", &Tokens::generate());
        assert_eq!(reg.id, "gmessages");
        assert_eq!(reg.sender_localpart, "gmessagesbot");
        assert!(reg.push_ephemeral && reg.receive_ephemeral);
        let res: Vec<Regex> = reg.namespaces.users.iter().map(|n| Regex::new(&n.regex).unwrap()).collect();
        let any = |s: &str| res.iter().any(|r| r.is_match(s));
        assert!(any("@gmessagesbot:example.com"));
        assert!(any("@gmessages_123.456:example.com"));
        assert!(!any("@gmessages_123:exampleXcom"), "dots in server name must be escaped");
        assert!(!any("@devon:example.com"));
        assert!(!any("@gmessages_1:example.com.evil"));
        assert!(reg.namespaces.users.iter().all(|n| n.exclusive));
    }

    #[test]
    fn yaml_round_trip_has_synapse_keys() {
        let reg = generate(&manifest(), "example.com", "http://127.0.0.1:1", &Tokens::generate());
        let y = reg.to_yaml();
        assert!(y.contains("de.sorunome.msc2409.push_ephemeral: true"));
        assert!(y.contains("sender_localpart: gmessagesbot"));
        let back: Registration = serde_yaml_ng::from_str(&y).unwrap();
        assert_eq!(back, reg);
    }

    #[test]
    fn ghost_regex_with_suffix() {
        let r = Regex::new(&ghost_regex("im_{{.}}_x", "a.b")).unwrap();
        assert!(r.is_match("@im_42_x:a.b"));
        assert!(!r.is_match("@im_42:a.b"));
    }

    #[test]
    fn double_puppet_has_null_url() {
        let dp = double_puppet("example.com", "tok");
        let y = dp.to_yaml();
        assert!(y.contains("url: null"));
        assert!(!dp.namespaces.users[0].exclusive);
    }
}
