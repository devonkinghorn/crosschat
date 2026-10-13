//! `crosschatd.toml`.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
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
    /// Local mode: let other devices (a phone through a reverse proxy) reach
    /// this server. See `remote.rs`.
    #[serde(default)]
    pub remote_access: RemoteAccessConfig,
}

/// `[remote_access]`: a second listener for other devices. It forwards only
/// the Matrix client-server API (`/_matrix/client`, `/_matrix/media`) to the
/// bundled homeserver, serves `/.well-known/matrix/client` and crosschatd's
/// user API. Bridges, appservice traffic, federation and local-only
/// endpoints stay on 127.0.0.1.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RemoteAccessConfig {
    #[serde(default)]
    pub enabled: bool,
    /// Address to listen on (`0.0.0.0` = every interface).
    #[serde(default = "default_remote_address")]
    pub address: IpAddr,
    #[serde(default = "default_remote_port")]
    pub port: u16,
    /// The URL other devices use, e.g. `https://matrix.example.com` (a
    /// reverse proxy in front of `address:port`). Served in
    /// `/.well-known/matrix/client`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_url: Option<String>,
}

pub const DEFAULT_REMOTE_PORT: u16 = 8008;

fn default_remote_address() -> IpAddr {
    IpAddr::V4(Ipv4Addr::UNSPECIFIED)
}
fn default_remote_port() -> u16 {
    DEFAULT_REMOTE_PORT
}

impl Default for RemoteAccessConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            address: default_remote_address(),
            port: DEFAULT_REMOTE_PORT,
            public_url: None,
        }
    }
}

impl RemoteAccessConfig {
    pub fn validate(&self) -> Result<()> {
        if let Some(u) = &self.public_url {
            let parsed =
                url::Url::parse(u).with_context(|| format!("public URL `{u}` isn't a URL"))?;
            if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
                bail!("public URL `{u}` must be an http(s) URL like https://matrix.example.com");
            }
            if parsed.query().is_some() || parsed.fragment().is_some() {
                bail!("public URL `{u}` can't have a query or fragment");
            }
        }
        if self.port == 0 {
            bail!("remote_access.port can't be 0");
        }
        Ok(())
    }
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
    /// Path to the homeserver binary. Omit it to let crosschatd find or
    /// install the pinned Tuwunel (see `tuwunel.rs`; `TUWUNEL_BIN` overrides).
    #[serde(default)]
    pub binary: Option<PathBuf>,
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
        self.remote_access.validate()?;
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

    /// Save `[remote_access]` to the config file on disk, keeping the rest of
    /// the file as it is.
    pub fn set_remote_access(path: &Path, ra: &RemoteAccessConfig) -> Result<()> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let mut doc: toml_edit::DocumentMut = text
            .parse()
            .with_context(|| format!("parsing {}", path.display()))?;
        let entry = doc
            .entry("remote_access")
            .or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()));
        let table = entry
            .as_table_like_mut()
            .with_context(|| format!("[remote_access] in {} is not a table", path.display()))?;
        table.insert("enabled", toml_edit::value(ra.enabled));
        table.insert("address", toml_edit::value(ra.address.to_string()));
        table.insert("port", toml_edit::value(i64::from(ra.port)));
        match &ra.public_url {
            Some(u) => {
                table.insert("public_url", toml_edit::value(u.as_str()));
            }
            None => {
                table.remove("public_url");
            }
        }
        let out = doc.to_string();
        Self::from_toml(&out)?;
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, out)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    /// Turn a bridge on or off in the config file on disk, keeping the rest
    /// of the file (comments, user edits) as it is.
    pub fn set_bridge_enabled(path: &Path, id: &str, enabled: bool) -> Result<()> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let mut doc: toml_edit::DocumentMut = text
            .parse()
            .with_context(|| format!("parsing {}", path.display()))?;
        let bridges = doc
            .entry("bridges")
            .or_insert_with(|| {
                let mut t = toml_edit::Table::new();
                t.set_implicit(true);
                toml_edit::Item::Table(t)
            })
            .as_table_mut()
            .with_context(|| format!("[bridges] in {} is not a table", path.display()))?;
        let entry = bridges
            .entry(id)
            .or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()));
        let table = entry
            .as_table_like_mut()
            .with_context(|| format!("[bridges.{id}] in {} is not a table", path.display()))?;
        table.insert("enabled", toml_edit::value(enabled));
        let out = doc.to_string();
        // Refuse to write something we couldn't load back.
        Self::from_toml(&out)?;
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, out)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn example() -> &'static str {
        include_str!("../../../deploy/crosschatd.example.toml")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_bridge_enabled_keeps_the_rest_of_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("crosschatd.toml");
        let text = "# my notes\ndata_dir = \"data\"\n[homeserver]\nurl = \"http://127.0.0.1:6167\"\nserver_name = \"localhost\"\n\n[bridges.gmessages]\nenabled = true # keep\nport = 29336\n\n[bridges.imessage]\nenabled = false\n";
        std::fs::write(&p, text).unwrap();
        Config::set_bridge_enabled(&p, "imessage", true).unwrap();
        Config::set_bridge_enabled(&p, "groupme", true).unwrap();
        let out = std::fs::read_to_string(&p).unwrap();
        assert!(out.starts_with("# my notes"), "{out}");
        assert!(out.contains("enabled = true # keep"), "{out}");
        let c = Config::load(&p).unwrap();
        assert!(c.bridges["imessage"].enabled);
        assert!(c.bridges["groupme"].enabled);
        assert_eq!(c.bridges["gmessages"].port, Some(29336));
        Config::set_bridge_enabled(&p, "imessage", false).unwrap();
        assert!(!Config::load(&p).unwrap().bridges["imessage"].enabled);
    }

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
