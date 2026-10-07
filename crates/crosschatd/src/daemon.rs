//! Orchestration: turns a [`Config`] into running bridges.

use crate::auth::{HomeserverValidator, TokenValidator};
use crate::bridge::{self, BridgeInputs, BridgeRuntime};
use crate::config::{Config, RegistrationMode};
use crate::homeserver;
use crate::installer;
use crate::manifest::{self, Manifest};
use crate::registration;
use crate::secrets::{Vault, write_private};
use crate::supervisor::{BackoffPolicy, ProcessHandle, spawn_supervised};
use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tracing::{error, info, warn};

pub struct Daemon {
    pub cfg: Config,
    pub manifests: Vec<Manifest>,
    pub bridges: BTreeMap<String, Arc<BridgeRuntime>>,
    pub admin_token: String,
    pub validator: Arc<dyn TokenValidator>,
    pub http: reqwest::Client,
    pub homeserver: Mutex<Option<ProcessHandle>>,
}

pub fn admin_token_path(cfg: &Config) -> PathBuf {
    cfg.data_dir.join("admin.token")
}

impl Daemon {
    /// Prepare every enabled bridge (install, config, registration), start
    /// the bundled homeserver if configured, then start bridges.
    pub async fn setup(cfg: Config) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&cfg.data_dir)
            .with_context(|| format!("creating {}", cfg.data_dir.display()))?;
        let http = reqwest::Client::builder()
            .user_agent(concat!("crosschatd/", env!("CARGO_PKG_VERSION")))
            .build()?;
        let mut vault = Vault::open(cfg.data_dir.join("vault.json"))?;
        let admin_token = vault.admin_token()?;
        write_private(&admin_token_path(&cfg), admin_token.as_bytes())?;
        let manifests = Manifest::load_dir(&cfg.manifests_dir)?;
        let platform = manifest::current_platform();
        let host_os = manifest::current_host_os();
        let reg_dir = cfg.registrations_dir();
        let dp_token = vault.doublepuppet_token()?;
        std::fs::create_dir_all(&reg_dir)?;
        write_private(
            &reg_dir.join("crosschat-doublepuppet.yaml"),
            registration::double_puppet(&cfg.homeserver.server_name, &dp_token)
                .to_yaml()
                .as_bytes(),
        )?;

        let mut bridges = BTreeMap::new();
        let mut taken_ports = vec![cfg.listen.port()];
        if let Some(b) = &cfg.homeserver.bundled {
            taken_ports.push(b.port);
        }
        let mut specs = Vec::new();
        for (id, bc) in cfg.bridges.iter().filter(|(_, b)| b.enabled) {
            let Some(m) = manifests.iter().find(|m| &m.id == id) else {
                error!(bridge = id, "enabled in config but no manifest found");
                continue;
            };
            let secrets = vault.bridge(id)?;
            let port = bridge::choose_port(bc.port, m.process.default_port, &taken_ports)?;
            taken_ports.push(port);
            let data_dir = cfg.data_dir.join("bridges").join(id);
            std::fs::create_dir_all(&data_dir)?;
            let rt = Arc::new(BridgeRuntime {
                manifest: m.clone(),
                port,
                data_dir: data_dir.clone(),
                secrets: secrets.clone(),
                handle: Mutex::new(None),
                health: Default::default(),
                remote_state: Mutex::new(None),
                setup_error: Mutex::new(None),
            });
            bridges.insert(id.clone(), rt.clone());

            let prepared: Result<_> = async {
                if !m.supports_host(host_os) {
                    anyhow::bail!("{} does not run on {host_os} hosts", m.display_name);
                }
                let binary = match &bc.binary {
                    Some(b) => b.clone(),
                    None => {
                        installer::ensure_installed(m, &cfg.data_dir.join("bin"), &platform, &http)
                            .await?
                    }
                };
                let inputs = BridgeInputs {
                    manifest: m,
                    cfg: &cfg,
                    secrets: &secrets,
                    doublepuppet_token: &dp_token,
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
            match prepared {
                Ok(spec) => specs.push((rt, spec)),
                Err(e) => {
                    error!(bridge = id, "setup failed: {e:#}");
                    *rt.setup_error.lock().unwrap() = Some(format!("{e:#}"));
                }
            }
        }

        let daemon = Arc::new(Daemon {
            validator: Arc::new(HomeserverValidator::new(http.clone(), &cfg.homeserver.url)),
            cfg,
            manifests,
            bridges,
            admin_token,
            http,
            homeserver: Mutex::new(None),
        });

        // Homeserver first: it must load the registrations before bridges start.
        if let Some(b) = daemon.cfg.homeserver.bundled.clone() {
            let token = vault.hs_registration_token()?;
            let spec = homeserver::prepare_bundled(&daemon.cfg, &b, &token)?;
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
                .bridges
                .keys()
                .map(|id| reg_dir.join(format!("{id}.yaml")))
                .collect();
            let refs: Vec<&std::path::Path> = files.iter().map(|p| p.as_path()).collect();
            match daemon.cfg.homeserver.registration {
                RegistrationMode::Manual => {
                    warn!("{}", homeserver::manual_instructions(&daemon.cfg, &refs))
                }
                RegistrationMode::Directory { .. } => {
                    info!("{}", homeserver::manual_instructions(&daemon.cfg, &refs))
                }
            }
        }

        for (rt, spec) in specs {
            let h = spawn_supervised(spec, BackoffPolicy::default(), true);
            *rt.handle.lock().unwrap() = Some(h);
            tokio::spawn(bridge::health_loop(rt.clone(), daemon.http.clone()));
        }
        Ok(daemon)
    }

    pub fn hs_handle(&self) -> Option<ProcessHandle> {
        self.homeserver.lock().unwrap().clone()
    }

    /// Stop bridges, then the homeserver.
    pub async fn shutdown(&self) {
        let handles: Vec<ProcessHandle> =
            self.bridges.values().filter_map(|b| b.handle()).collect();
        for h in &handles {
            h.stop();
        }
        for h in &handles {
            h.wait_for(Duration::from_secs(15), |s| {
                *s == crate::supervisor::ProcState::Stopped
            })
            .await;
        }
        if let Some(h) = self.hs_handle() {
            h.stop();
            h.wait_for(Duration::from_secs(15), |s| {
                *s == crate::supervisor::ProcState::Stopped
            })
            .await;
        }
    }
}
