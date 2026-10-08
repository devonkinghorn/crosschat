//! Orchestration: turns a [`Config`] into running bridges, and turns bridges
//! on and off at runtime ("Add network" in the app).

use crate::auth::{HomeserverValidator, TokenValidator};
use crate::bridge::{self, BridgeInputs, BridgeRuntime};
use crate::config::{BridgeConfig, Config, RegistrationMode};
use crate::homeserver;
use crate::installer;
use crate::local_setup;
use crate::manifest::{self, Manifest};
use crate::registration;
use crate::secrets::{Vault, write_private};
use crate::supervisor::{BackoffPolicy, ProcState, ProcessHandle, ProcessSpec, spawn_supervised};
use crate::tuwunel::{self, Progress};
use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;
use tracing::{error, info, warn};

pub struct Daemon {
    pub cfg: Config,
    pub manifests: Vec<Manifest>,
    /// Enabled bridges (including ones whose setup failed: they carry
    /// `setup_error`). Changes at runtime when networks are added/removed.
    pub bridges: RwLock<BTreeMap<String, Arc<BridgeRuntime>>>,
    pub admin_token: String,
    pub validator: Arc<dyn TokenValidator>,
    pub http: reqwest::Client,
    pub homeserver: Mutex<Option<ProcessHandle>>,
    /// `auth.admins`, plus owners added at runtime (local-mode owner bootstrap).
    pub admins: RwLock<Vec<String>>,
    /// The config file, if enabling/disabling bridges should be saved to it.
    pub config_path: Option<PathBuf>,
    /// What an enable in progress is doing ("Downloading iMessage"), by bridge id.
    pub progress: Mutex<BTreeMap<String, String>>,
    /// Last enable failure for bridges that aren't in `bridges`.
    pub enable_errors: Mutex<BTreeMap<String, String>>,
    /// Registrations (id → YAML) the running bundled homeserver loaded at
    /// startup: Tuwunel reads `appservice_dir` only then, so a new or changed
    /// registration needs a homeserver restart.
    hs_loaded: Mutex<BTreeMap<String, String>>,
    /// Enable/disable/remove run one at a time.
    ops: tokio::sync::Mutex<()>,
    keep_awake: Mutex<Option<std::process::Child>>,
}

pub fn admin_token_path(cfg: &Config) -> PathBuf {
    cfg.data_dir.join("admin.token")
}

fn vault_path(cfg: &Config) -> PathBuf {
    cfg.data_dir.join("vault.json")
}

/// Read every registration in `dir` (id from the file name → contents).
fn read_registrations(dir: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("yaml")
                && let (Some(stem), Ok(text)) = (
                    p.file_stem().and_then(|s| s.to_str()),
                    std::fs::read_to_string(&p),
                )
            {
                out.insert(stem.to_string(), text);
            }
        }
    }
    out
}

impl Daemon {
    /// Prepare every enabled bridge (install, config, registration), start
    /// the bundled homeserver if configured, then start bridges.
    pub async fn setup(cfg: Config) -> Result<Arc<Self>> {
        Self::setup_with_progress(cfg, Arc::new(|_| {}), None).await
    }

    /// [`Daemon::setup`], reporting human-readable progress (local mode
    /// shows it in the app's setup screen). With `config_path`, bridges
    /// turned on or off at runtime are saved to that file.
    pub async fn setup_with_progress(
        cfg: Config,
        progress: Progress,
        config_path: Option<PathBuf>,
    ) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&cfg.data_dir)
            .with_context(|| format!("creating {}", cfg.data_dir.display()))?;
        let http = reqwest::Client::builder()
            .user_agent(concat!("crosschatd/", env!("CARGO_PKG_VERSION")))
            .build()?;
        let mut vault = Vault::open(vault_path(&cfg))?;
        let admin_token = vault.admin_token()?;
        write_private(&admin_token_path(&cfg), admin_token.as_bytes())?;
        let manifests = Manifest::load_dir(&cfg.manifests_dir)?;
        let reg_dir = cfg.registrations_dir();
        let dp_token = vault.doublepuppet_token()?;
        std::fs::create_dir_all(&reg_dir)?;
        write_private(
            &reg_dir.join("crosschat-doublepuppet.yaml"),
            registration::double_puppet(&cfg.homeserver.server_name, &dp_token)
                .to_yaml()
                .as_bytes(),
        )?;

        // Resolve the homeserver binary first: on a fresh install without a
        // bundled copy this downloads Tuwunel, and a failure should surface early.
        let hs_binary = match &cfg.homeserver.bundled {
            Some(b) => Some(
                tuwunel::resolve(b.binary.as_deref(), &http, progress.clone())
                    .await
                    .context("finding the Tuwunel homeserver binary")?,
            ),
            None => None,
        };

        let mut daemon = Daemon::from_parts(
            cfg,
            manifests,
            BTreeMap::new(),
            admin_token,
            Arc::new(HomeserverValidator::new(http.clone(), "")),
            http.clone(),
        );
        daemon.validator = Arc::new(HomeserverValidator::new(
            http.clone(),
            &daemon.cfg.homeserver.url,
        ));
        daemon.config_path = config_path;
        let daemon = Arc::new(daemon);

        let mut specs = Vec::new();
        let enabled: Vec<(String, BridgeConfig)> = daemon
            .cfg
            .bridges
            .iter()
            .filter(|(_, b)| b.enabled)
            .map(|(id, b)| (id.clone(), b.clone()))
            .collect();
        for (id, bc) in enabled {
            let Some(m) = daemon.manifest(&id).cloned() else {
                error!(bridge = id, "enabled in config but no manifest found");
                continue;
            };
            progress(format!("Setting up {}", m.display_name));
            let (rt, prepared) = daemon.prepare(&m, &bc, &mut vault, &dp_token).await?;
            daemon
                .bridges
                .write()
                .unwrap()
                .insert(id.clone(), rt.clone());
            match prepared {
                Ok(spec) => specs.push((rt, spec)),
                Err(e) => {
                    error!(bridge = id, "setup failed: {e:#}");
                    *rt.setup_error.lock().unwrap() = Some(format!("{e:#}"));
                }
            }
        }

        // Homeserver first: it must load the registrations before bridges start.
        if let (Some(b), Some(bin)) = (daemon.cfg.homeserver.bundled.clone(), &hs_binary) {
            progress("Starting the Matrix server".into());
            let token = vault.hs_registration_token()?;
            let spec = homeserver::prepare_bundled(&daemon.cfg, &b, bin, &token)?;
            *daemon.hs_loaded.lock().unwrap() = read_registrations(&reg_dir);
            let h = spawn_supervised(spec, BackoffPolicy::default(), true);
            *daemon.homeserver.lock().unwrap() = Some(h);
            info!("waiting for bundled homeserver on port {}", b.port);
            if !homeserver::wait_ready(
                &daemon.http,
                &daemon.cfg.homeserver.url,
                Duration::from_secs(90),
            )
            .await
            {
                warn!("bundled homeserver not ready after 90s; starting bridges anyway");
            }
        } else {
            let files: Vec<PathBuf> = daemon
                .bridge_ids()
                .iter()
                .map(|id| reg_dir.join(format!("{id}.yaml")))
                .collect();
            let refs: Vec<&Path> = files.iter().map(|p| p.as_path()).collect();
            match daemon.cfg.homeserver.registration {
                RegistrationMode::Manual => {
                    warn!("{}", homeserver::manual_instructions(&daemon.cfg, &refs))
                }
                RegistrationMode::Directory { .. } => {
                    info!("{}", homeserver::manual_instructions(&daemon.cfg, &refs))
                }
            }
        }

        if !specs.is_empty() {
            progress("Starting bridges".into());
        }
        for (rt, spec) in specs {
            daemon.start_or_gate(&rt, spec).await;
        }
        daemon.update_keep_awake();
        Ok(daemon)
    }

    /// Assemble a daemon from already-prepared parts (no processes are
    /// started). Used by tests and embedders.
    pub fn from_parts(
        cfg: Config,
        manifests: Vec<Manifest>,
        bridges: BTreeMap<String, Arc<BridgeRuntime>>,
        admin_token: String,
        validator: Arc<dyn TokenValidator>,
        http: reqwest::Client,
    ) -> Self {
        Daemon {
            admins: RwLock::new(cfg.auth.admins.clone()),
            cfg,
            manifests,
            bridges: RwLock::new(bridges),
            admin_token,
            validator,
            http,
            homeserver: Mutex::new(None),
            config_path: None,
            progress: Default::default(),
            enable_errors: Default::default(),
            hs_loaded: Default::default(),
            ops: Default::default(),
            keep_awake: Mutex::new(None),
        }
    }

    pub fn manifest(&self, id: &str) -> Option<&Manifest> {
        self.manifests.iter().find(|m| m.id == id)
    }

    /// The runtime of an enabled bridge.
    pub fn bridge(&self, id: &str) -> Option<Arc<BridgeRuntime>> {
        self.bridges.read().unwrap().get(id).cloned()
    }

    pub fn bridge_list(&self) -> Vec<Arc<BridgeRuntime>> {
        self.bridges.read().unwrap().values().cloned().collect()
    }

    pub fn bridge_ids(&self) -> Vec<String> {
        self.bridges.read().unwrap().keys().cloned().collect()
    }

    /// Current admin list (config admins plus runtime additions).
    pub fn admin_list(&self) -> Vec<String> {
        self.admins.read().unwrap().clone()
    }

    /// Grant admin rights at runtime (local-mode owner bootstrap).
    pub fn add_admin(&self, user_id: &str) {
        let mut a = self.admins.write().unwrap();
        if !a.iter().any(|x| x == user_id) {
            a.push(user_id.to_string());
        }
    }

    pub fn hs_handle(&self) -> Option<ProcessHandle> {
        self.homeserver.lock().unwrap().clone()
    }

    /// Config with the runtime admin list, so bridges started after the
    /// owner was created give them admin rights.
    fn effective_cfg(&self) -> Config {
        let mut cfg = self.cfg.clone();
        cfg.auth.admins = self.admin_list();
        cfg
    }

    fn taken_ports(&self, except: Option<&str>) -> Vec<u16> {
        let mut taken = vec![self.cfg.listen.port()];
        if let Some(b) = &self.cfg.homeserver.bundled {
            taken.push(b.port);
        }
        taken.extend(
            self.bridges
                .read()
                .unwrap()
                .iter()
                .filter(|(id, _)| Some(id.as_str()) != except)
                .map(|(_, rt)| rt.port),
        );
        taken
    }

    /// Install the binary and write config + registration. The outer error
    /// is for broken daemon state (vault, ports); the inner one is the
    /// bridge's own setup failure, shown to the user as `setup_error`.
    async fn prepare(
        &self,
        m: &Manifest,
        bc: &BridgeConfig,
        vault: &mut Vault,
        dp_token: &str,
    ) -> Result<(Arc<BridgeRuntime>, Result<ProcessSpec>)> {
        let id = &m.id;
        let secrets = vault.bridge(id)?;
        // Keep the port the bridge had (its registration URL) when possible.
        let taken = self.taken_ports(Some(id));
        let previous = bridge::registration_url_port(&self.cfg.registrations_dir(), id)
            .filter(|p| !taken.contains(p));
        let port = bridge::choose_port(bc.port.or(previous), m.process.default_port, &taken)?;
        let data_dir = self.cfg.data_dir.join("bridges").join(id);
        std::fs::create_dir_all(&data_dir)?;
        let rt = Arc::new(BridgeRuntime::new(
            m.clone(),
            port,
            data_dir.clone(),
            secrets.clone(),
        ));
        let cfg = self.effective_cfg();
        let host_os = manifest::current_host_os();
        let platform = manifest::current_platform();
        let reg_dir = cfg.registrations_dir();
        let prepared: Result<ProcessSpec> = async {
            if !m.supports_host(host_os) {
                bail!("{} does not run on {host_os} hosts", m.display_name);
            }
            let binary = match &bc.binary {
                Some(b) => b.clone(),
                None => {
                    self.set_progress(id, Some(format!("Installing {}", m.display_name)));
                    installer::ensure_installed(m, &cfg.data_dir.join("bin"), &platform, &self.http)
                        .await?
                }
            };
            self.set_progress(id, Some(format!("Configuring {}", m.display_name)));
            let inputs = BridgeInputs {
                manifest: m,
                cfg: &cfg,
                secrets: &secrets,
                doublepuppet_token: dp_token,
                port,
                data_dir: &data_dir,
            };
            let ctx = bridge::template_context(&inputs);
            let cfg_path = bridge::config_path(&data_dir);
            let base = if cfg_path.exists() {
                Some(serde_yaml_ng::from_str(&std::fs::read_to_string(
                    &cfg_path,
                )?)?)
            } else {
                bridge::generate_example_config(m, &binary, &ctx, &data_dir).await?
            };
            let value = bridge::build_config(base, &inputs)?;
            let reg = bridge::registration_for(&inputs);
            bridge::write_files(&value, &reg, &data_dir, &reg_dir)?;
            bridge::process_spec(m, &binary, &ctx, &data_dir)
        }
        .await;
        Ok((rt, prepared))
    }

    fn start_bridge(&self, rt: &Arc<BridgeRuntime>, spec: ProcessSpec) {
        let h = spawn_supervised(spec, BackoffPolicy::default(), true);
        *rt.handle.lock().unwrap() = Some(h);
        tokio::spawn(bridge::health_loop(rt.clone(), self.http.clone()));
    }

    fn set_progress(&self, id: &str, what: Option<String>) {
        let mut p = self.progress.lock().unwrap();
        match what {
            Some(w) => {
                info!(bridge = id, "{w}");
                p.insert(id.to_string(), w);
            }
            None => {
                p.remove(id);
            }
        }
    }

    pub fn progress_of(&self, id: &str) -> Option<String> {
        self.progress.lock().unwrap().get(id).cloned()
    }

    fn save_enabled(&self, id: &str, enabled: bool) {
        if let Some(path) = &self.config_path
            && let Err(e) = Config::set_bridge_enabled(path, id, enabled)
        {
            warn!(bridge = id, "couldn't save to {}: {e:#}", path.display());
        }
    }

    /// Make the bundled homeserver load the registrations on disk, restarting
    /// it only if they changed since it started. Clients and other bridges
    /// reconnect by themselves; nothing is lost.
    async fn reload_registrations(&self, id: &str, name: &str) -> Result<()> {
        let Some(hs) = self.hs_handle() else {
            // External homeserver: the admin registers the file.
            if matches!(self.cfg.homeserver.registration, RegistrationMode::Manual) {
                let file = self.cfg.registrations_dir().join(format!("{id}.yaml"));
                warn!(
                    "{}",
                    homeserver::manual_instructions(&self.cfg, &[file.as_path()])
                );
            }
            return Ok(());
        };
        let on_disk = read_registrations(&self.cfg.registrations_dir());
        let loaded = self.hs_loaded.lock().unwrap().clone();
        let needed = on_disk.get(id).is_some_and(|r| loaded.get(id) != Some(r));
        if !needed {
            return Ok(());
        }
        self.set_progress(
            id,
            Some(format!("Restarting the Matrix server to add {name}")),
        );
        hs.restart();
        // Wait for the old process to go away, then for the new one to answer.
        hs.wait_for(Duration::from_secs(20), |s| {
            !matches!(s, ProcState::Running { .. })
        })
        .await;
        hs.wait_for(Duration::from_secs(30), |s| {
            matches!(s, ProcState::Running { .. })
        })
        .await;
        if !homeserver::wait_ready(
            &self.http,
            &self.cfg.homeserver.url,
            Duration::from_secs(90),
        )
        .await
        {
            bail!("the Matrix server didn't come back after restarting");
        }
        *self.hs_loaded.lock().unwrap() = on_disk;
        Ok(())
    }

    /// Turn a bridge on: install the prebuilt binary, write its config and
    /// registration, make the homeserver load it, start it. Progress is in
    /// [`Daemon::progress_of`]; failures in `setup_error`/`enable_errors`.
    /// Mark `id` as being enabled right away (before [`Daemon::enable`] runs
    /// in the background), so `GET /networks` never shows a stale error.
    pub fn begin_enable(&self, id: &str) {
        if let Some(m) = self.manifest(id) {
            self.enable_errors.lock().unwrap().remove(id);
            if let Some(rt) = self.bridge(id) {
                *rt.setup_error.lock().unwrap() = None;
            }
            self.set_progress(id, Some(format!("Starting {}", m.display_name)));
        }
    }

    pub async fn enable(&self, id: &str) -> Result<()> {
        let _op = self.ops.lock().await;
        let m = self
            .manifest(id)
            .cloned()
            .with_context(|| format!("no bridge called `{id}`"))?;
        if let Some(rt) = self.bridge(id)
            && rt.handle().is_some()
        {
            // Already on: make sure it runs.
            if let Some(h) = rt.handle() {
                h.start();
            }
            self.set_progress(id, None);
            return Ok(());
        }
        self.enable_errors.lock().unwrap().remove(id);
        let result = self.enable_inner(&m).await;
        self.set_progress(id, None);
        if let Err(e) = &result {
            error!(bridge = id, "enable failed: {e:#}");
            let msg = format!("{e:#}");
            match self.bridge(id) {
                Some(rt) => *rt.setup_error.lock().unwrap() = Some(msg),
                None => {
                    self.enable_errors
                        .lock()
                        .unwrap()
                        .insert(id.to_string(), msg);
                }
            }
        }
        self.update_keep_awake();
        result
    }

    async fn enable_inner(&self, m: &Manifest) -> Result<()> {
        let id = &m.id;
        if !m.supports_host(manifest::current_host_os()) {
            bail!(
                "{} doesn't run on this computer ({})",
                m.display_name,
                manifest::current_host_os()
            );
        }
        let bc = self.cfg.bridges.get(id).cloned().unwrap_or_default();
        let mut vault = Vault::open(vault_path(&self.cfg))?;
        let dp_token = vault.doublepuppet_token()?;
        let (rt, prepared) = self.prepare(m, &bc, &mut vault, &dp_token).await?;
        // Listed from now on (with setup_error if the next steps fail).
        self.bridges.write().unwrap().insert(id.clone(), rt.clone());
        let spec = prepared?;
        self.save_enabled(id, true);
        self.reload_registrations(id, &m.display_name).await?;
        self.set_progress(id, Some(format!("Starting {}", m.display_name)));
        if self.start_or_gate(&rt, spec).await {
            let h = rt.handle().unwrap();
            h.wait_for(Duration::from_secs(10), |s| {
                matches!(s, ProcState::Running { .. })
            })
            .await;
        }
        Ok(())
    }

    /// Start a prepared bridge, unless it has a `local_setup` whose sign-in
    /// flow the user hasn't finished, or whose permissions are gone (it would
    /// only exit and be restarted over and over). Returns whether it started.
    async fn start_or_gate(&self, rt: &Arc<BridgeRuntime>, spec: ProcessSpec) -> bool {
        if rt.manifest.local_setup.is_some() {
            *rt.gated_spec.lock().unwrap() = Some(spec.clone());
            if !local_setup::is_set_up(&rt.data_dir) {
                info!(
                    bridge = rt.manifest.id,
                    "not started until its sign-in is done"
                );
                return false;
            }
            let problem = local_setup::start_problem(&rt.manifest, &spec.program).await;
            let blocked = problem.is_some();
            if let Some(p) = &problem {
                warn!(bridge = rt.manifest.id, "not starting: {p}");
            }
            *rt.setup_problem.lock().unwrap() = problem;
            if blocked {
                return false;
            }
        }
        self.start_bridge(rt, spec);
        true
    }

    /// The sign-in flow of a `local_setup` bridge finished: remember that and
    /// start the bridge.
    pub fn finish_local_setup(&self, id: &str) -> Result<()> {
        let rt = self
            .bridge(id)
            .with_context(|| format!("`{id}` is not enabled"))?;
        write_private(&local_setup::marker_path(&rt.data_dir), b"1\n")?;
        *rt.setup_problem.lock().unwrap() = None;
        match rt.handle() {
            Some(h) => h.start(),
            None => {
                let spec = rt
                    .gated_spec
                    .lock()
                    .unwrap()
                    .clone()
                    .with_context(|| format!("`{id}` failed setup"))?;
                self.start_bridge(&rt, spec);
            }
        }
        info!(bridge = id, "sign-in done, bridge started");
        self.update_keep_awake();
        Ok(())
    }

    /// Sign out of a `local_setup` bridge: stop it and forget the sign-in.
    /// Its data and chats stay; signing in again resumes.
    pub async fn undo_local_setup(&self, id: &str) -> Result<()> {
        let rt = self
            .bridge(id)
            .with_context(|| format!("`{id}` is not enabled"))?;
        let _ = std::fs::remove_file(local_setup::marker_path(&rt.data_dir));
        if let Some(h) = rt.handle() {
            h.stop();
            h.wait_for(Duration::from_secs(20), |s| *s == ProcState::Stopped)
                .await;
        }
        self.update_keep_awake();
        Ok(())
    }

    /// Turn a bridge off: stop it and drop its registration. Its data
    /// (logins, chats) stays, so turning it back on resumes where it was.
    pub async fn disable(&self, id: &str) -> Result<()> {
        let _op = self.ops.lock().await;
        self.disable_inner(id).await;
        self.save_enabled(id, false);
        self.update_keep_awake();
        Ok(())
    }

    async fn disable_inner(&self, id: &str) {
        let rt = self.bridges.write().unwrap().remove(id);
        self.enable_errors.lock().unwrap().remove(id);
        if let Some(rt) = rt {
            rt.retired.store(true, Ordering::Relaxed);
            if let Some(h) = rt.handle() {
                h.stop();
                h.wait_for(Duration::from_secs(20), |s| *s == ProcState::Stopped)
                    .await;
            }
        }
        // The running homeserver keeps the registration loaded until its next
        // restart; it just can't reach the bridge meanwhile.
        let _ = std::fs::remove_file(self.cfg.registrations_dir().join(format!("{id}.yaml")));
    }

    /// Remove a network: sign out of every account on it (best effort), stop
    /// it and delete its data. Its rooms stay in the user's Matrix account.
    pub async fn remove(&self, id: &str) -> Result<()> {
        let _op = self.ops.lock().await;
        if let Some(rt) = self.bridge(id)
            && rt.manifest.local_setup.is_none()
            && matches!(rt.proc_state(), ProcState::Running { .. })
        {
            let users: Vec<String> = self.admin_list();
            for user in users {
                if let Ok(url) = crate::proxy::upstream_url(rt.port, "v3/logout/all", None, &user) {
                    let r = self
                        .http
                        .post(url)
                        .bearer_auth(&rt.secrets.provisioning_secret)
                        .json(&serde_json::json!({}))
                        .timeout(Duration::from_secs(20))
                        .send()
                        .await;
                    if let Err(e) = r {
                        warn!(bridge = id, "logout before removal failed: {e}");
                    }
                }
            }
        }
        self.disable_inner(id).await;
        let data = self.cfg.data_dir.join("bridges").join(id);
        if data.starts_with(&self.cfg.data_dir) && data.exists() {
            std::fs::remove_dir_all(&data)
                .with_context(|| format!("deleting {}", data.display()))?;
        }
        // New tokens next time it's added.
        let mut vault = Vault::open(vault_path(&self.cfg))?;
        vault.forget_bridge(id)?;
        self.save_enabled(id, false);
        self.update_keep_awake();
        Ok(())
    }

    /// macOS: hold a `caffeinate -i` assertion (no idle sleep; the display
    /// may still sleep) while a bridge that needs the Mac awake is enabled.
    fn update_keep_awake(&self) {
        if !cfg!(target_os = "macos") {
            return;
        }
        let needed = self
            .bridges
            .read()
            .unwrap()
            .values()
            .any(|rt| rt.manifest.keep_awake && rt.handle().is_some() && !rt.awaiting_setup());
        let mut ka = self.keep_awake.lock().unwrap();
        if let Some(child) = ka.as_mut()
            && child.try_wait().ok().flatten().is_some()
        {
            *ka = None;
        }
        match (needed, ka.is_some()) {
            (true, false) => {
                let pid = std::process::id().to_string();
                match std::process::Command::new("/usr/bin/caffeinate")
                    .args(["-i", "-w", &pid])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                {
                    Ok(c) => {
                        info!("keeping this Mac awake while iMessage runs (caffeinate -i)");
                        *ka = Some(c);
                    }
                    Err(e) => warn!("couldn't start caffeinate: {e}"),
                }
            }
            (false, true) => {
                if let Some(mut c) = ka.take() {
                    let _ = c.kill();
                    let _ = c.wait();
                }
            }
            _ => {}
        }
    }

    pub fn keeping_awake(&self) -> bool {
        self.keep_awake.lock().unwrap().is_some()
    }

    /// Stop bridges, then the homeserver.
    pub async fn shutdown(&self) {
        let handles: Vec<ProcessHandle> = self
            .bridge_list()
            .iter()
            .filter_map(|b| b.handle())
            .collect();
        for h in &handles {
            h.stop();
        }
        for h in &handles {
            h.wait_for(Duration::from_secs(15), |s| *s == ProcState::Stopped)
                .await;
        }
        if let Some(h) = self.hs_handle() {
            h.stop();
            h.wait_for(Duration::from_secs(15), |s| *s == ProcState::Stopped)
                .await;
        }
        if let Some(mut c) = self.keep_awake.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}
