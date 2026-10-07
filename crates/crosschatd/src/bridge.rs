//! Per-bridge preparation (config + registration) and runtime state.

use crate::config::Config;
use crate::manifest::Manifest;
use crate::registration::{self, Registration};
use crate::secrets::{BridgeSecrets, write_private};
use crate::supervisor::{ProcState, ProcessHandle, ProcessSpec};
use crate::template::{self, Context, deep_merge, set_path};
use anyhow::{Context as _, Result};
use serde::Serialize;
use serde_yaml_ng::{Mapping, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

/// Inputs needed to render a bridge's config.
pub struct BridgeInputs<'a> {
    pub manifest: &'a Manifest,
    pub cfg: &'a Config,
    pub secrets: &'a BridgeSecrets,
    pub doublepuppet_token: &'a str,
    pub port: u16,
    pub data_dir: &'a Path,
}

pub fn config_path(data_dir: &Path) -> PathBuf {
    data_dir.join("config.yaml")
}

pub fn registration_path(data_dir: &Path) -> PathBuf {
    data_dir.join("registration.yaml")
}

pub fn template_context(i: &BridgeInputs) -> Context {
    let mut c = Context::new();
    let d = i.data_dir.display().to_string();
    c.insert("data_dir".into(), d);
    c.insert(
        "config".into(),
        config_path(i.data_dir).display().to_string(),
    );
    c.insert(
        "registration".into(),
        registration_path(i.data_dir).display().to_string(),
    );
    c.insert("port".into(), i.port.to_string());
    c.insert("bridge.id".into(), i.manifest.id.clone());
    c.insert("hs.url".into(), i.cfg.homeserver.url.clone());
    c.insert(
        "hs.server_name".into(),
        i.cfg.homeserver.server_name.clone(),
    );
    c.insert("crosschatd.url".into(), i.cfg.internal_url());
    c
}

/// Build the final bridge config: example config ← manifest `config` ←
/// crosschatd-managed keys (tokens, ports, homeserver, permissions).
pub fn build_config(base: Option<Value>, i: &BridgeInputs) -> Result<Value> {
    let ctx = template_context(i);
    let mut cfg = base
        .filter(Value::is_mapping)
        .unwrap_or_else(|| Value::Mapping(Mapping::new()));
    if !i.manifest.config.is_null() {
        let overlay = template::render_value(&i.manifest.config, &ctx)
            .context("rendering manifest config")?;
        deep_merge(&mut cfg, &overlay);
    }
    let s = |v: &str| Value::String(v.to_string());
    let hs = &i.cfg.homeserver;
    let r = &i.manifest.registration;
    let id = &i.manifest.id;
    let managed: Vec<(&[&str], Value)> = vec![
        (&["homeserver", "address"], s(&hs.url)),
        (&["homeserver", "domain"], s(&hs.server_name)),
        (
            &["homeserver", "status_endpoint"],
            s(&format!(
                "{}/_crosschat/internal/bridge-status/{id}",
                i.cfg.internal_url()
            )),
        ),
        (
            &["appservice", "address"],
            s(&format!("http://127.0.0.1:{}", i.port)),
        ),
        (&["appservice", "hostname"], s("127.0.0.1")),
        (&["appservice", "port"], Value::Number(i.port.into())),
        (&["appservice", "id"], s(id)),
        (&["appservice", "bot", "username"], s(&r.bot_username)),
        (
            &["appservice", "username_template"],
            s(&r.username_template),
        ),
        (
            &["appservice", "ephemeral_events"],
            Value::Bool(r.ephemeral_events),
        ),
        (&["appservice", "as_token"], s(&i.secrets.tokens.as_token)),
        (&["appservice", "hs_token"], s(&i.secrets.tokens.hs_token)),
        (&["database", "type"], s("sqlite3-fk-wal")),
        (
            &["database", "uri"],
            s(&format!(
                "file:{}/bridge.db?_txlock=immediate",
                i.data_dir.display()
            )),
        ),
        (
            &["provisioning", "shared_secret"],
            s(&i.secrets.provisioning_secret),
        ),
        (&["provisioning", "allow_matrix_auth"], Value::Bool(true)),
        (&["encryption", "pickle_key"], s(&i.secrets.pickle_key)),
        (
            &["logging"],
            serde_yaml_ng::from_str(
                "min_level: info\nwriters:\n  - type: stdout\n    format: pretty",
            )?,
        ),
    ];
    for (path, value) in managed {
        set_path(&mut cfg, path, value);
    }
    // Permissions: local users may use the bridge, configured admins administer it.
    let mut perms = Mapping::new();
    perms.insert(s(&hs.server_name), s("user"));
    for a in &i.cfg.auth.admins {
        perms.insert(s(a), s("admin"));
    }
    set_path(&mut cfg, &["bridge", "permissions"], Value::Mapping(perms));
    let mut dp = Mapping::new();
    dp.insert(
        s(&hs.server_name),
        s(&format!("as_token:{}", i.doublepuppet_token)),
    );
    set_path(&mut cfg, &["double_puppet", "secrets"], Value::Mapping(dp));
    Ok(cfg)
}

pub fn registration_for(i: &BridgeInputs) -> Registration {
    registration::generate(
        i.manifest,
        &i.cfg.homeserver.server_name,
        &format!("http://127.0.0.1:{}", i.port),
        &i.secrets.tokens,
    )
}

/// Write config + registration to the bridge data dir and to the homeserver
/// registration directory.
pub fn write_files(
    cfg_value: &Value,
    reg: &Registration,
    data_dir: &Path,
    reg_dir: &Path,
) -> Result<()> {
    std::fs::create_dir_all(data_dir)?;
    write_private(
        &config_path(data_dir),
        serde_yaml_ng::to_string(cfg_value)?.as_bytes(),
    )?;
    write_private(&registration_path(data_dir), reg.to_yaml().as_bytes())?;
    std::fs::create_dir_all(reg_dir)?;
    write_private(
        &reg_dir.join(format!("{}.yaml", reg.id)),
        reg.to_yaml().as_bytes(),
    )?;
    Ok(())
}

pub fn process_spec(
    manifest: &Manifest,
    binary: &Path,
    ctx: &Context,
    data_dir: &Path,
) -> Result<ProcessSpec> {
    let args = manifest
        .process
        .args
        .iter()
        .map(|a| template::render(a, ctx))
        .collect::<Result<Vec<_>, _>>()?;
    let env = manifest
        .process
        .env
        .iter()
        .map(|(k, v)| Ok((k.clone(), template::render(v, ctx)?)))
        .collect::<Result<Vec<_>, template::TemplateError>>()?;
    Ok(ProcessSpec {
        name: manifest.id.clone(),
        program: binary.to_path_buf(),
        args,
        env,
        cwd: Some(data_dir.to_path_buf()),
        log_file: Some(data_dir.join("bridge.log")),
    })
}

/// Run the bridge's "write example config" command, returning the parsed
/// example config (if the manifest declares one).
pub async fn generate_example_config(
    manifest: &Manifest,
    binary: &Path,
    ctx: &Context,
    data_dir: &Path,
) -> Result<Option<Value>> {
    let Some(args) = &manifest.process.generate_example_config else {
        return Ok(None);
    };
    let args = args
        .iter()
        .map(|a| template::render(a, ctx))
        .collect::<Result<Vec<_>, _>>()?;
    let path = config_path(data_dir);
    let out = tokio::time::timeout(
        Duration::from_secs(60),
        tokio::process::Command::new(binary)
            .args(&args)
            .current_dir(data_dir)
            .output(),
    )
    .await
    .context("example config generation timed out")??;
    if !path.exists() {
        anyhow::bail!(
            "{} {:?} did not write {}: {}",
            binary.display(),
            args,
            path.display(),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(Some(serde_yaml_ng::from_str(&std::fs::read_to_string(
        &path,
    )?)?))
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Health {
    pub live: Option<bool>,
    pub ready: Option<bool>,
    pub consecutive_failures: u32,
    pub last_error: Option<String>,
}

/// A configured bridge at runtime.
pub struct BridgeRuntime {
    pub manifest: Manifest,
    pub port: u16,
    pub data_dir: PathBuf,
    pub secrets: BridgeSecrets,
    pub handle: Mutex<Option<ProcessHandle>>,
    pub health: Mutex<Health>,
    /// Last state pushed by the bridge to the status endpoint.
    pub remote_state: Mutex<Option<serde_json::Value>>,
    pub setup_error: Mutex<Option<String>>,
}

impl BridgeRuntime {
    pub fn proc_state(&self) -> ProcState {
        self.handle
            .lock()
            .unwrap()
            .as_ref()
            .map(|h| h.state())
            .unwrap_or(ProcState::Stopped)
    }

    pub fn handle(&self) -> Option<ProcessHandle> {
        self.handle.lock().unwrap().clone()
    }

    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
}

/// Health-check loop: polls liveness/readiness, restarts after repeated
/// liveness failures while the process claims to be running.
pub async fn health_loop(rt: std::sync::Arc<BridgeRuntime>, http: reqwest::Client) {
    let spec = rt.manifest.health.clone();
    let grace = Duration::from_secs(30);
    let mut interval = tokio::time::interval(Duration::from_secs(spec.interval_secs.max(1)));
    loop {
        interval.tick().await;
        let Some(handle) = rt.handle() else { continue };
        let running_for = match handle.state() {
            ProcState::Running { started_at_ms, .. } => {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as u64;
                Duration::from_millis(now.saturating_sub(started_at_ms))
            }
            _ => {
                let mut h = rt.health.lock().unwrap();
                h.live = None;
                h.ready = None;
                continue;
            }
        };
        let get = |path: String| {
            let http = http.clone();
            let url = format!("{}{}", rt.base_url(), path);
            async move {
                http.get(url)
                    .timeout(Duration::from_secs(5))
                    .send()
                    .await
                    .map(|r| r.status().is_success())
            }
        };
        let live = get(spec.liveness.clone()).await;
        let ready = get(spec.readiness.clone()).await;
        let restart = {
            let mut h = rt.health.lock().unwrap();
            h.ready = ready.as_ref().ok().copied();
            match live {
                Ok(true) => {
                    h.live = Some(true);
                    h.consecutive_failures = 0;
                    h.last_error = None;
                    false
                }
                other => {
                    h.live = Some(false);
                    h.last_error = Some(match other {
                        Ok(_) => "liveness returned non-2xx".into(),
                        Err(e) => e.to_string(),
                    });
                    if running_for > grace {
                        h.consecutive_failures += 1;
                    }
                    h.consecutive_failures >= spec.failures_before_restart
                }
            }
        };
        if restart {
            tracing::warn!(bridge = rt.manifest.id, "liveness failing, restarting");
            rt.health.lock().unwrap().consecutive_failures = 0;
            handle.restart();
        }
    }
}

/// Pick the appservice port: configured, else upstream default if free, else
/// any free port.
pub fn choose_port(configured: Option<u16>, default_port: u16, taken: &[u16]) -> Result<u16> {
    if let Some(p) = configured {
        return Ok(p);
    }
    let free =
        |p: u16| !taken.contains(&p) && std::net::TcpListener::bind(("127.0.0.1", p)).is_ok();
    if free(default_port) {
        return Ok(default_port);
    }
    for _ in 0..20 {
        let p = std::net::TcpListener::bind(("127.0.0.1", 0))?
            .local_addr()?
            .port();
        if free(p) {
            return Ok(p);
        }
    }
    anyhow::bail!("no free port found")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::registration::Tokens;
    use crate::secrets::BridgeSecrets;

    fn setup() -> (Manifest, Config, BridgeSecrets) {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let m = Manifest::load(&root.join("manifests/slack.yaml")).unwrap();
        let c = Config::from_toml(Config::example()).unwrap();
        let s = BridgeSecrets {
            tokens: Tokens {
                as_token: "AS".into(),
                hs_token: "HS".into(),
            },
            provisioning_secret: "PROV".into(),
            pickle_key: "PICKLE".into(),
        };
        (m, c, s)
    }

    #[test]
    fn managed_keys_override_example_config() {
        let (m, c, s) = setup();
        let dir = Path::new("/var/lib/crosschat/bridges/slack");
        let i = BridgeInputs {
            manifest: &m,
            cfg: &c,
            secrets: &s,
            doublepuppet_token: "DP",
            port: 29335,
            data_dir: dir,
        };
        let example: Value = serde_yaml_ng::from_str(
            "appservice: {as_token: generate, port: 8008, bot: {displayname: Slack bridge bot}}\nnetwork: {foo: bar}\nprovisioning: {shared_secret: generate}",
        )
        .unwrap();
        let cfg = build_config(Some(example), &i).unwrap();
        let g = |p: &[&str]| template::get_path(&cfg, p).cloned();
        assert_eq!(
            g(&["appservice", "as_token"]),
            Some(Value::String("AS".into()))
        );
        assert_eq!(
            g(&["appservice", "port"]),
            Some(Value::Number(29335.into()))
        );
        assert_eq!(
            g(&["appservice", "bot", "displayname"]),
            Some(Value::String("Slack bridge bot".into())),
            "unmanaged keys survive"
        );
        assert_eq!(g(&["network", "foo"]), Some(Value::String("bar".into())));
        assert_eq!(
            g(&["provisioning", "shared_secret"]),
            Some(Value::String("PROV".into()))
        );
        assert_eq!(
            g(&["homeserver", "domain"]),
            Some(Value::String("example.com".into()))
        );
        assert_eq!(
            g(&["homeserver", "status_endpoint"]),
            Some(Value::String(
                "http://127.0.0.1:29300/_crosschat/internal/bridge-status/slack".into()
            ))
        );
        assert_eq!(
            g(&["double_puppet", "secrets", "example.com"]),
            Some(Value::String("as_token:DP".into()))
        );
        assert_eq!(
            g(&["bridge", "permissions", "@devon:example.com"]),
            Some(Value::String("admin".into()))
        );
        assert_eq!(
            g(&["database", "uri"]),
            Some(Value::String(
                "file:/var/lib/crosschat/bridges/slack/bridge.db?_txlock=immediate".into()
            ))
        );
    }

    #[test]
    fn registration_matches_config() {
        let (m, c, s) = setup();
        let i = BridgeInputs {
            manifest: &m,
            cfg: &c,
            secrets: &s,
            doublepuppet_token: "DP",
            port: 4000,
            data_dir: Path::new("/d"),
        };
        let reg = registration_for(&i);
        assert_eq!(reg.url.as_deref(), Some("http://127.0.0.1:4000"));
        assert_eq!(reg.as_token, "AS");
        let cfg = build_config(None, &i).unwrap();
        assert_eq!(
            template::get_path(&cfg, &["appservice", "bot", "username"])
                .unwrap()
                .as_str(),
            Some(reg.sender_localpart.as_str())
        );
    }

    #[test]
    fn process_args_are_rendered() {
        let (m, c, s) = setup();
        let d = Path::new("/d");
        let i = BridgeInputs {
            manifest: &m,
            cfg: &c,
            secrets: &s,
            doublepuppet_token: "DP",
            port: 1,
            data_dir: d,
        };
        let spec = process_spec(
            &m,
            Path::new("/bin/mautrix-slack"),
            &template_context(&i),
            d,
        )
        .unwrap();
        assert!(
            spec.args.contains(&"/d/config.yaml".to_string()),
            "{:?}",
            spec.args
        );
        assert!(spec.args.contains(&"/d/registration.yaml".to_string()));
    }

    #[test]
    fn port_selection() {
        assert_eq!(choose_port(Some(1234), 29335, &[]).unwrap(), 1234);
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let busy = l.local_addr().unwrap().port();
        let p = choose_port(None, busy, &[]).unwrap();
        assert_ne!(p, busy);
    }
}
