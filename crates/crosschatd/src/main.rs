use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crosschatd::{api, config::Config, daemon, manifest::Manifest, registration};
use std::path::PathBuf;
use tracing::info;

#[derive(Parser)]
#[command(name = "crosschatd", version, about = "Crosschat host daemon: runs and manages Matrix bridges")]
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
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    match Cli::parse().cmd {
        Cmd::Run { config } => {
            let cfg = Config::load(&config)?;
            let listen = cfg.listen;
            let d = daemon::Daemon::setup(cfg).await?;
            let listener = tokio::net::TcpListener::bind(listen).await.with_context(|| format!("binding {listen}"))?;
            info!("crosschatd API listening on http://{listen}/_crosschat/v1/health");
            let app = api::router(d.clone());
            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = tokio::signal::ctrl_c().await;
                })
                .await?;
            info!("shutting down");
            d.shutdown().await;
        }
        Cmd::Validate { dir } => {
            let all = Manifest::load_dir(&dir)?;
            for m in &all {
                println!("ok  {:<10} {:<28} {:?} ({})", m.id, m.display_name, m.maturity, m.license);
            }
            println!("{} manifests valid", all.len());
        }
        Cmd::Registration { manifest, server_name, url } => {
            let m = Manifest::load(&manifest)?;
            let reg = registration::generate(&m, &server_name, &url, &registration::Tokens::generate());
            print!("{}", reg.to_yaml());
        }
        Cmd::ExampleConfig => print!("{}", Config::example()),
        Cmd::Status { config } => {
            let cfg = Config::load(&config)?;
            let token = std::fs::read_to_string(daemon::admin_token_path(&cfg)).context("reading admin token (is the daemon set up?)")?;
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
