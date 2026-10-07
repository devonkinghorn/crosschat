//! `crosschatd.toml`.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Address of the HTTP API (control + provisioning proxy). Put it behind
    /// the homeserver's reverse proxy at `/_crosschat/`.
    #[serde(default = "default_listen")]
    pub listen: SocketAddr,
    /// URL bridges use to reach crosschatd (bridge status endpoint).
    #[serde(default)]
    pub internal_url: Option<String>,
    pub data_dir: PathBuf,
    #[serde(default = "default_manifests")]
    pub manifests_dir: PathBuf,
    pub homeserver: HomeserverConfig,
    #[serde(default)]
    pub auth: AuthConfig,
    #[serde(default)]
    pub bridges: BTreeMap<String, BridgeConfig>,
}

fn default_listen() -> SocketAddr {
    "127.0.0.1:29300".parse().unwrap()
}

fn default_manifests() -> PathBuf {
    PathBuf::from("manifests")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HomeserverConfig {
    /// Client-server URL as reachable from this host (bridges use it too).
    pub url: String,
    /// The Matrix server name (the part after `:` in user IDs).
    pub server_name: String,
    /// How registrations reach the homeserver.
    #[serde(default)]
    pub registration: RegistrationMode,
    /// Run a bundled homeserver as a supervised child process.
    #[serde(default)]
    pub bundled: Option<BundledConfig>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RegistrationMode {
    /// Write registration files to `<data_dir>/registrations` and print
    /// instructions (Synapse `app_service_config_files`, Continuwuity admin
    /// room command).
    #[default]
    Manual,
    /// Write registration files into a directory the homeserver loads at
    /// startup (Tuwunel `appservice_dir`).
    Directory { path: PathBuf },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundledConfig {
    /// Only `tuwunel` is implemented in the alpha.
    #[serde(default = "default_impl")]
    pub implementation: String,
    /// Path to the homeserver binary.
    pub binary: PathBuf,
    #[serde(default = "default_hs_port")]
    pub port: u16,
    /// Federation must be chosen explicitly at setup: `false` = private
    /// (only accounts on this server), `true` = federated.
    pub federation: Option<bool>,
    /// Allow registration with the vault's registration token (owner
    /// bootstrap). Turn off after creating accounts.
    #[serde(default)]
    pub allow_registration: bool,
}

fn default_impl() -> String {
    "tuwunel".into()
}
fn default_hs_port() -> u16 {
    6167
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthConfig {
    /// MXIDs allowed to manage bridges and use the provisioning proxy.
    #[serde(default)]
    pub admins: Vec<String>,
    /// Also allow any user on `server_name` to use the provisioning proxy
    /// (bridge management stays admin-only).
    #[serde(default)]
    pub allow_server_users: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BridgeConfig {
    #[serde(default)]
    pub enabled: bool,
    /// Use an already-installed binary instead of downloading one.
    #[serde(default)]
    pub binary: Option<PathBuf>,
    /// Fixed appservice port (default: manifest default if free, else random).
    #[serde(default)]
    pub port: Option<u16>,
}

impl Config {
    pub fn from_toml(text: &str) -> Result<Self> {
        let cfg: Config = toml::from_str(text).context("invalid crosschatd config")?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn load(path: &Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let mut cfg = Self::from_toml(&text)?;
        // Relative paths are relative to the config file.
        let base = path.parent().unwrap_or(Path::new("."));
        if cfg.data_dir.is_relative() {
            cfg.data_dir = base.join(&cfg.data_dir);
        }
        if cfg.manifests_dir.is_relative() {
            cfg.manifests_dir = base.join(&cfg.manifests_dir);
        }
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<()> {
        if self.homeserver.server_name.trim().is_empty() {
            bail!("homeserver.server_name is required");
        }
        if !self.homeserver.url.starts_with("http") {
            bail!("homeserver.url must be an http(s) URL");
        }
        if let Some(b) = &self.homeserver.bundled {
            if b.implementation != "tuwunel" {
                bail!(
                    "bundled homeserver `{}` is not supported yet (only tuwunel)",
                    b.implementation
                );
            }
            if b.federation.is_none() {
                bail!(
                    "homeserver.bundled.federation must be set explicitly: false = private, true = federated \
                     (server_name cannot be changed later)"
                );
            }
        }
        for a in &self.auth.admins {
            if !a.starts_with('@') || !a.contains(':') {
                bail!("auth.admins entry `{a}` is not a Matrix user ID");
            }
        }
        Ok(())
    }

    pub fn internal_url(&self) -> String {
        self.internal_url
            .clone()
            .unwrap_or_else(|| format!("http://{}", self.listen))
    }

    pub fn registrations_dir(&self) -> PathBuf {
        match &self.homeserver.registration {
            RegistrationMode::Directory { path } => path.clone(),
            RegistrationMode::Manual => self.data_dir.join("registrations"),
        }
    }

    pub fn example() -> &'static str {
        include_str!("../../../deploy/crosschatd.example.toml")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn example_config_parses() {
        let c = Config::from_toml(Config::example()).unwrap();
        assert_eq!(c.homeserver.server_name, "example.com");
        assert!(c.bridges.contains_key("gmessages"));
    }

    #[test]
    fn bundled_requires_explicit_federation_choice() {
        let t = r#"
data_dir = "/tmp/x"
[homeserver]
url = "http://127.0.0.1:6167"
server_name = "example.com"
[homeserver.bundled]
binary = "/usr/bin/tuwunel"
"#;
        let err = Config::from_toml(t).unwrap_err().to_string();
        assert!(err.contains("federation must be set explicitly"), "{err}");
        let ok = format!("{t}federation = false\n");
        assert!(Config::from_toml(&ok).is_ok());
    }

    #[test]
    fn rejects_bad_admin() {
        let t = "data_dir='/x'\n[homeserver]\nurl='http://h'\nserver_name='e'\n[auth]\nadmins=['devon']\n";
        assert!(Config::from_toml(t).is_err());
    }
}
