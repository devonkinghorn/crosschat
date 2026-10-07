use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crosschatd::{
    api, config::Config, daemon, installer, local, manifest, manifest::Manifest, registration,
    tuwunel,
};
use std::path::PathBuf;
use tracing::info;

#[derive(Parser)]
#[command(
    name = "crosschatd",
    version,
    about = "Crosschat host daemon: runs and manages Matrix bridges"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the daemon.
    Run {
        #[arg(short, long, default_value = "crosschatd.toml")]
        config: PathBuf,
    },
    /// Validate bridge manifests.
    Validate {
        #[arg(default_value = "manifests")]
        dir: PathBuf,
    },
    /// Print a fresh appservice registration for a manifest.
    Registration {
        manifest: PathBuf,
        #[arg(long)]
        server_name: String,
        #[arg(long, default_value = "http://127.0.0.1:29336")]
        url: String,
    },
    /// Run a private homeserver + bridges for this computer only (what the
    /// desktop app starts): server_name `localhost`, bundled Tuwunel on
    /// 127.0.0.1, no federation. Everything lives in `--dir`.
    Local {
        #[arg(long)]
        dir: PathBuf,
        /// crosschatd API address (only used when generating crosschatd.toml).
        #[arg(long, default_value = local::DEFAULT_LISTEN)]
        listen: std::net::SocketAddr,
        /// Tuwunel port (only used when generating crosschatd.toml).
        #[arg(long, default_value_t = local::DEFAULT_HS_PORT)]
        hs_port: u16,
        /// Bridges to enable (only used when generating crosschatd.toml).
        #[arg(long, value_delimiter = ',', default_value = "gmessages,slack")]
        bridges: Vec<String>,
    },
    /// Download the pinned, prebuilt Tuwunel into the cache (unless one is
    /// already found) and print its path. Honors TUWUNEL_BIN and
    /// CROSSCHAT_CACHE_DIR.
    InstallTuwunel {
        /// Developer option (macOS): build the pinned tag with cargo instead.
        #[arg(long)]
        from_source: bool,
    },
    /// Download prebuilt bridge binaries into DEST/<id>/<version>/ (how
    /// scripts/bundle-local-server.sh fills the app's bridges/ directory).
    FetchBridges {
        #[arg(long)]
        dest: PathBuf,
        /// Platform key, e.g. darwin-arm64 (default: this computer).
        #[arg(long)]
        platform: Option<String>,
        /// Bridge ids (default: the bridges local mode enables).
        ids: Vec<String>,
    },
    /// Print an example config file.
    ExampleConfig,
    /// Show daemon status (uses the local admin token).
    Status {
        #[arg(short, long, default_value = "crosschatd.toml")]
        config: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let filter =
        || tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into());
    if let Cmd::Local { dir, .. } = &cli.cmd {
        // The app starts us detached (no stdio): log to <dir>/crosschatd.log.
        use tracing_subscriber::fmt::writer::MakeWriterExt;
        std::fs::create_dir_all(dir)?;
        let log_path = local::LocalPaths::new(dir).log();
        if std::fs::metadata(&log_path).is_ok_and(|m| m.len() > 10 << 20) {
            let _ = std::fs::rename(&log_path, log_path.with_extension("log.1"));
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)?;
        tracing_subscriber::fmt()
            .with_env_filter(filter())
            .with_ansi(false)
            .with_writer(std::io::stderr.and(std::sync::Mutex::new(file)))
            .init();
    } else {
        // stdout is for command output (install-tuwunel / fetch-bridges print
        // paths that scripts capture); logs go to stderr.
        tracing_subscriber::fmt()
            .with_env_filter(filter())
            .with_writer(std::io::stderr)
            .init();
    }
    match cli.cmd {
        Cmd::Local {
            dir,
            listen,
            hs_port,
            bridges,
        } => {
            let opts = local::LocalOptions {
                listen,
                hs_port,
                bridges,
            };
            if let Err(e) = local::run(local::LocalPaths::new(&dir), opts).await {
                tracing::error!("{e:#}");
                return Err(e);
            }
        }
        Cmd::InstallTuwunel { from_source } => {
            let progress: tuwunel::Progress = std::sync::Arc::new(|s| eprintln!("{s}"));
            let http = reqwest::Client::new();
            let p = if from_source {
                tuwunel::install(&tuwunel::cache_dir(), &http, progress, true).await?
            } else {
                tuwunel::resolve(None, &http, progress).await?
            };
            println!("{}", p.display());
        }
        Cmd::FetchBridges {
            dest,
            platform,
            ids,
        } => {
            let platform = platform.unwrap_or_else(manifest::current_platform);
            let ids = if ids.is_empty() {
                local::DEFAULT_BRIDGES
                    .iter()
                    .map(|s| s.to_string())
                    .collect()
            } else {
                ids
            };
            let http = reqwest::Client::new();
            for id in &ids {
                let (name, text) = local::EMBEDDED_MANIFESTS
                    .iter()
                    .find(|(n, _)| n.trim_end_matches(".yaml") == id)
                    .with_context(|| format!("no manifest for bridge `{id}`"))?;
                let m = Manifest::from_yaml(text, name)?;
                let target = installer::install_path(&m, &dest, &platform);
                if !target.is_file() {
                    installer::fetch(&m, &target, &platform, &http).await?;
                }
                let _ = std::fs::remove_file(target.with_extension("sha256"));
                println!("{}", target.display());
            }
        }
        Cmd::Run { config } => {
            let cfg = Config::load(&config)?;
            let listen = cfg.listen;
            let d = daemon::Daemon::setup(cfg).await?;
            let listener = tokio::net::TcpListener::bind(listen)
                .await
                .with_context(|| format!("binding {listen}"))?;
            info!("crosschatd API listening on http://{listen}/_crosschat/v1/health");
            let app = api::router(d.clone());
            axum::serve(listener, app)
                .with_graceful_shutdown(local::shutdown_signal())
                .await?;
            info!("shutting down");
            d.shutdown().await;
        }
        Cmd::Validate { dir } => {
            let all = Manifest::load_dir(&dir)?;
            for m in &all {
                println!(
                    "ok  {:<10} {:<28} {:?} ({})",
                    m.id, m.display_name, m.maturity, m.license
                );
            }
            println!("{} manifests valid", all.len());
        }
        Cmd::Registration {
            manifest,
            server_name,
            url,
        } => {
            let m = Manifest::load(&manifest)?;
            let reg =
                registration::generate(&m, &server_name, &url, &registration::Tokens::generate());
            print!("{}", reg.to_yaml());
        }
        Cmd::ExampleConfig => print!("{}", Config::example()),
        Cmd::Status { config } => {
            let cfg = Config::load(&config)?;
            let token = std::fs::read_to_string(daemon::admin_token_path(&cfg))
                .context("reading admin token (is the daemon set up?)")?;
            let v: serde_json::Value = reqwest::Client::new()
                .get(format!("http://{}/_crosschat/v1/networks", cfg.listen))
                .bearer_auth(token.trim())
                .send()
                .await?
                .json()
                .await?;
            println!("{}", serde_json::to_string_pretty(&v)?);
        }
    }
    Ok(())
}
