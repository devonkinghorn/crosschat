//! Turning bridges on and off at runtime against a real Tuwunel ("Add
//! network" in the app). Needs `TUWUNEL_BIN` and python3 (for a stand-in
//! bridge); skipped otherwise. scripts/smoke.sh runs it.

use crosschatd::local::{self, LocalOptions, LocalPaths, LocalServer, Phase};
use crosschatd::supervisor::ProcState;
use std::time::Duration;

const FAKE_MANIFEST: &str = r#"
schema: crosschat.bridge/v1
id: fake
display_name: Fake Network
network: fake
framework: bridgev2
license: MIT
host_platforms: [linux, macos]
source:
  kind: github-release
  repo: example/fake
  version: v1
  artifacts:
    linux-amd64: fake
  sha256:
    linux-amd64: 0000000000000000000000000000000000000000000000000000000000000000
process:
  binary: fake_bridge.py
  args: ["-c", "{{config}}", "-r", "{{registration}}"]
  generate_example_config: ["-e", "-c", "{{config}}"]
  default_port: 29399
registration:
  bot_username: fakebot
  username_template: "fake_{{.}}"
"#;

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn pid(s: ProcState) -> Option<u32> {
    match s {
        ProcState::Running { pid, .. } => Some(pid),
        _ => None,
    }
}

/// Does the homeserver know the appservice's bot user (created when it
/// loads the registration)?
async fn bot_exists(http: &reqwest::Client, hs: &str) -> bool {
    let r = http
        .get(format!("{hs}/_matrix/client/v3/profile/@fakebot:localhost"))
        .send()
        .await
        .unwrap();
    r.status().is_success()
}

#[tokio::test(flavor = "multi_thread")]
async fn enable_disable_remove_with_real_tuwunel() {
    if std::env::var_os("TUWUNEL_BIN").is_none() {
        eprintln!("skipped: set TUWUNEL_BIN");
        return;
    }
    if std::process::Command::new("python3")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipped: no python3");
        return;
    }
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();
    let dir = tempfile::tempdir().unwrap();
    let paths = LocalPaths::new(dir.path().join("server"));
    let opts = LocalOptions {
        listen: format!("127.0.0.1:{}", free_port()).parse().unwrap(),
        hs_port: free_port(),
        bridges: vec![],
    };
    local::prepare(&paths, &opts).unwrap();
    // A stand-in bridge: its manifest next to the real ones, its binary from config.
    std::fs::write(paths.manifests().join("fake.yaml"), FAKE_MANIFEST).unwrap();
    let script =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_bridge.py");
    // Tuwunel comes from $TUWUNEL_BIN.
    let mut toml = std::fs::read_to_string(paths.config()).unwrap();
    toml.push_str(&format!(
        "\n[bridges.fake]\nenabled = false\nbinary = \"{}\"\n",
        script.display()
    ));
    std::fs::write(paths.config(), toml).unwrap();
    let cfg = local::prepare(&paths, &opts).unwrap();
    let hs = cfg.homeserver.url.clone();
    let reg_file = cfg.registrations_dir().join("fake.yaml");
    let bridge_dir = cfg.data_dir.join("bridges/fake");

    let server = LocalServer::new(paths.clone(), cfg).unwrap();
    server.setup().await;
    assert_eq!(server.status().phase, Phase::Ready, "{:?}", server.status());
    let d = server.daemon().unwrap().clone();
    let http = reqwest::Client::new();
    let hs_pid = || pid(d.hs_handle().unwrap().state());
    let first_pid = hs_pid().expect("homeserver running");
    assert!(!bot_exists(&http, &hs).await);
    assert!(d.bridge("fake").is_none());

    // Enable: config + registration written, homeserver restarted to load it,
    // bridge running, choice saved.
    d.enable("fake").await.unwrap();
    let rt = d.bridge("fake").expect("enabled");
    assert!(rt.setup_error.lock().unwrap().is_none());
    assert!(matches!(rt.proc_state(), ProcState::Running { .. }));
    assert!(reg_file.exists());
    let second_pid = hs_pid().expect("homeserver back up");
    assert_ne!(
        first_pid, second_pid,
        "homeserver restarted to load the registration"
    );
    assert!(bot_exists(&http, &hs).await, "registration loaded");
    let saved = crosschatd::config::Config::load(&paths.config()).unwrap();
    assert!(saved.bridges["fake"].enabled);
    assert!(d.progress_of("fake").is_none());

    // Enabling again is a no-op.
    d.enable("fake").await.unwrap();
    assert_eq!(hs_pid(), Some(second_pid));

    // Disable: stopped, registration gone, data kept, choice saved.
    d.disable("fake").await.unwrap();
    assert!(d.bridge("fake").is_none());
    assert!(!reg_file.exists());
    assert!(bridge_dir.join("config.yaml").exists());
    assert!(
        !crosschatd::config::Config::load(&paths.config())
            .unwrap()
            .bridges["fake"]
            .enabled
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rt.proc_state(), ProcState::Stopped);

    // Re-enable: same registration as the homeserver already has, no restart.
    d.enable("fake").await.unwrap();
    assert_eq!(
        hs_pid(),
        Some(second_pid),
        "no restart for an unchanged registration"
    );
    assert!(matches!(
        d.bridge("fake").unwrap().proc_state(),
        ProcState::Running { .. }
    ));

    // Remove: data deleted, secrets forgotten.
    d.remove("fake").await.unwrap();
    assert!(d.bridge("fake").is_none());
    assert!(!bridge_dir.exists());
    assert!(!reg_file.exists());

    // Unknown bridge: error, nothing listed.
    assert!(d.enable("nope").await.is_err());
    d.shutdown().await;
}
