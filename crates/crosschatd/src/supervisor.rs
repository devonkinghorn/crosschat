//! Generic process supervisor with exponential backoff.
//!
//! Each supervised process gets its own task. The pure restart policy
//! ([`RestartTracker`]) is separated from the I/O so it can be unit-tested.

use serde::Serialize;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, watch};
use tracing::{info, warn};

#[derive(Debug, Clone, PartialEq)]
pub struct BackoffPolicy {
    pub initial: Duration,
    pub max: Duration,
    pub factor: f64,
    /// A run longer than this counts as healthy and resets the backoff.
    pub reset_after: Duration,
    /// Give up after this many consecutive short-lived runs (`None` = never).
    pub max_failures: Option<u32>,
}

impl Default for BackoffPolicy {
    fn default() -> Self {
        Self {
            initial: Duration::from_secs(1),
            max: Duration::from_secs(300),
            factor: 2.0,
            reset_after: Duration::from_secs(120),
            max_failures: Some(10),
        }
    }
}

impl BackoffPolicy {
    /// Delay before restart number `attempt` (1-based).
    pub fn delay(&self, attempt: u32) -> Duration {
        let exp = self.factor.powi(attempt.saturating_sub(1).min(32) as i32);
        let secs = (self.initial.as_secs_f64() * exp).min(self.max.as_secs_f64());
        Duration::from_secs_f64(secs)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    RestartAfter(Duration),
    GiveUp,
}

#[derive(Debug, Clone)]
pub struct RestartTracker {
    policy: BackoffPolicy,
    consecutive_failures: u32,
}

impl RestartTracker {
    pub fn new(policy: BackoffPolicy) -> Self {
        Self { policy, consecutive_failures: 0 }
    }

    pub fn consecutive_failures(&self) -> u32 {
        self.consecutive_failures
    }

    pub fn reset(&mut self) {
        self.consecutive_failures = 0;
    }

    /// Called when the process exits unexpectedly after running `ran_for`.
    pub fn on_exit(&mut self, ran_for: Duration) -> Decision {
        if ran_for >= self.policy.reset_after {
            self.consecutive_failures = 0;
        }
        self.consecutive_failures += 1;
        if let Some(max) = self.policy.max_failures
            && self.consecutive_failures > max
        {
            return Decision::GiveUp;
        }
        Decision::RestartAfter(self.policy.delay(self.consecutive_failures))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ProcState {
    Stopped,
    Starting,
    Running { pid: u32, started_at_ms: u64 },
    Backoff { attempt: u32, retry_in_ms: u64, last_exit: String },
    Failed { reason: String },
}

#[derive(Debug, Clone)]
pub struct ProcessSpec {
    pub name: String,
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<PathBuf>,
    pub log_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cmd {
    Start,
    Stop,
    Restart,
}

const LOG_LINES: usize = 1000;

#[derive(Clone)]
pub struct ProcessHandle {
    pub name: String,
    tx: mpsc::UnboundedSender<Cmd>,
    state: watch::Receiver<ProcState>,
    logs: Arc<Mutex<VecDeque<String>>>,
    restarts: Arc<AtomicU32>,
}

impl ProcessHandle {
    pub fn start(&self) {
        let _ = self.tx.send(Cmd::Start);
    }
    pub fn stop(&self) {
        let _ = self.tx.send(Cmd::Stop);
    }
    pub fn restart(&self) {
        let _ = self.tx.send(Cmd::Restart);
    }
    pub fn state(&self) -> ProcState {
        self.state.borrow().clone()
    }
    pub fn subscribe(&self) -> watch::Receiver<ProcState> {
        self.state.clone()
    }
    pub fn restarts(&self) -> u32 {
        self.restarts.load(Ordering::Relaxed)
    }
    pub fn logs(&self, n: usize) -> Vec<String> {
        let l = self.logs.lock().unwrap();
        l.iter().skip(l.len().saturating_sub(n)).cloned().collect()
    }
    /// Wait until `pred` holds for the state, or time out.
    pub async fn wait_for(&self, timeout: Duration, pred: impl Fn(&ProcState) -> bool) -> bool {
        let mut rx = self.state.clone();
        tokio::time::timeout(timeout, async {
            loop {
                if pred(&rx.borrow_and_update()) {
                    return;
                }
                if rx.changed().await.is_err() {
                    return;
                }
            }
        })
        .await
        .is_ok()
            && pred(&self.state.borrow())
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Spawn a supervisor task for `spec`.
pub fn spawn_supervised(spec: ProcessSpec, policy: BackoffPolicy, autostart: bool) -> ProcessHandle {
    let (tx, rx) = mpsc::unbounded_channel();
    let (state_tx, state_rx) = watch::channel(ProcState::Stopped);
    let logs = Arc::new(Mutex::new(VecDeque::with_capacity(LOG_LINES)));
    let restarts = Arc::new(AtomicU32::new(0));
    let handle = ProcessHandle { name: spec.name.clone(), tx, state: state_rx, logs: logs.clone(), restarts: restarts.clone() };
    tokio::spawn(run(spec, policy, autostart, rx, state_tx, logs, restarts));
    handle
}

fn push_log(logs: &Mutex<VecDeque<String>>, line: String) {
    let mut l = logs.lock().unwrap();
    if l.len() >= LOG_LINES {
        l.pop_front();
    }
    l.push_back(line);
}

fn spawn_child(spec: &ProcessSpec, logs: &Arc<Mutex<VecDeque<String>>>) -> std::io::Result<Child> {
    let mut cmd = Command::new(&spec.program);
    cmd.args(&spec.args)
        .envs(spec.env.iter().cloned())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = &spec.cwd {
        cmd.current_dir(cwd);
    }
    let mut child = cmd.spawn()?;
    let file = spec.log_file.clone();
    let (out, err) = (child.stdout.take(), child.stderr.take());
    let (ltx, mut lrx) = mpsc::unbounded_channel::<String>();
    if let Some(out) = out {
        let ltx = ltx.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(out).lines();
            while let Ok(Some(l)) = lines.next_line().await {
                let _ = ltx.send(l);
            }
        });
    }
    if let Some(err) = err {
        tokio::spawn(async move {
            let mut lines = BufReader::new(err).lines();
            while let Ok(Some(l)) = lines.next_line().await {
                let _ = ltx.send(l);
            }
        });
    }
    let logs = logs.clone();
    tokio::spawn(async move {
        let mut f = match &file {
            Some(p) => tokio::fs::OpenOptions::new().create(true).append(true).open(p).await.ok(),
            None => None,
        };
        while let Some(line) = lrx.recv().await {
            if let Some(f) = f.as_mut() {
                let _ = f.write_all(format!("{line}\n").as_bytes()).await;
            }
            push_log(&logs, line);
        }
    });
    Ok(child)
}

async fn terminate(child: &mut Child, name: &str) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // SAFETY: plain syscall on a pid we own.
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
        if tokio::time::timeout(Duration::from_secs(10), child.wait()).await.is_ok() {
            return;
        }
        warn!(name, "did not exit after SIGTERM, killing");
    }
    let _ = child.kill().await;
}

async fn run(
    spec: ProcessSpec,
    policy: BackoffPolicy,
    autostart: bool,
    mut rx: mpsc::UnboundedReceiver<Cmd>,
    state: watch::Sender<ProcState>,
    logs: Arc<Mutex<VecDeque<String>>>,
    restarts: Arc<AtomicU32>,
) {
    let name = spec.name.clone();
    let mut want_running = autostart;
    let mut tracker = RestartTracker::new(policy);
    loop {
        if !want_running {
            let _ = state.send(ProcState::Stopped);
            match rx.recv().await {
                Some(Cmd::Start | Cmd::Restart) => {
                    want_running = true;
                    tracker.reset();
                }
                Some(Cmd::Stop) => {}
                None => return,
            }
            continue;
        }

        let _ = state.send(ProcState::Starting);
        let (last_exit, ran_for) = match spawn_child(&spec, &logs) {
            Err(e) => (format!("spawn failed: {e}"), Duration::ZERO),
            Ok(mut child) => {
                let pid = child.id().unwrap_or(0);
                info!(name, pid, "started");
                let _ = state.send(ProcState::Running { pid, started_at_ms: now_ms() });
                let started = Instant::now();
                let outcome = loop {
                    tokio::select! {
                        status = child.wait() => {
                            break Some(match status {
                                Ok(s) => format!("exited: {s}"),
                                Err(e) => format!("wait failed: {e}"),
                            });
                        }
                        cmd = rx.recv() => match cmd {
                            Some(Cmd::Start) => continue,
                            Some(Cmd::Stop) => {
                                terminate(&mut child, &name).await;
                                want_running = false;
                                break None;
                            }
                            Some(Cmd::Restart) => {
                                terminate(&mut child, &name).await;
                                tracker.reset();
                                restarts.fetch_add(1, Ordering::Relaxed);
                                break None;
                            }
                            None => {
                                terminate(&mut child, &name).await;
                                return;
                            }
                        }
                    }
                };
                match outcome {
                    Some(exit) => (exit, started.elapsed()),
                    None => continue, // stop/restart handled
                }
            }
        };

        warn!(name, %last_exit, "process exited unexpectedly");
        push_log(&logs, format!("[crosschatd] {name} {last_exit}"));
        match tracker.on_exit(ran_for) {
            Decision::GiveUp => {
                let reason = format!("gave up after {} quick failures; last: {last_exit}", tracker.consecutive_failures() - 1);
                let _ = state.send(ProcState::Failed { reason });
                want_running = false;
                // Wait for an explicit start/restart.
                match rx.recv().await {
                    Some(Cmd::Start | Cmd::Restart) => {
                        want_running = true;
                        tracker.reset();
                    }
                    Some(Cmd::Stop) => {}
                    None => return,
                }
            }
            Decision::RestartAfter(delay) => {
                let _ = state.send(ProcState::Backoff {
                    attempt: tracker.consecutive_failures(),
                    retry_in_ms: delay.as_millis() as u64,
                    last_exit,
                });
                tokio::select! {
                    _ = tokio::time::sleep(delay) => { restarts.fetch_add(1, Ordering::Relaxed); }
                    cmd = rx.recv() => match cmd {
                        Some(Cmd::Stop) => want_running = false,
                        Some(Cmd::Start | Cmd::Restart) => { restarts.fetch_add(1, Ordering::Relaxed); }
                        None => return,
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fast_policy(max_failures: Option<u32>) -> BackoffPolicy {
        BackoffPolicy {
            initial: Duration::from_millis(20),
            max: Duration::from_millis(80),
            factor: 2.0,
            reset_after: Duration::from_secs(60),
            max_failures,
        }
    }

    #[test]
    fn backoff_grows_and_caps() {
        let p = BackoffPolicy::default();
        assert_eq!(p.delay(1), Duration::from_secs(1));
        assert_eq!(p.delay(2), Duration::from_secs(2));
        assert_eq!(p.delay(5), Duration::from_secs(16));
        assert_eq!(p.delay(30), Duration::from_secs(300));
        assert_eq!(p.delay(u32::MAX), Duration::from_secs(300));
    }

    #[test]
    fn tracker_resets_after_healthy_run_and_gives_up() {
        let mut t = RestartTracker::new(BackoffPolicy { max_failures: Some(3), ..Default::default() });
        assert_eq!(t.on_exit(Duration::from_secs(1)), Decision::RestartAfter(Duration::from_secs(1)));
        assert_eq!(t.on_exit(Duration::from_secs(1)), Decision::RestartAfter(Duration::from_secs(2)));
        // A long healthy run resets the counter.
        assert_eq!(t.on_exit(Duration::from_secs(600)), Decision::RestartAfter(Duration::from_secs(1)));
        assert_eq!(t.on_exit(Duration::ZERO), Decision::RestartAfter(Duration::from_secs(2)));
        assert_eq!(t.on_exit(Duration::ZERO), Decision::RestartAfter(Duration::from_secs(4)));
        assert_eq!(t.on_exit(Duration::ZERO), Decision::GiveUp);
    }

    fn sh(name: &str, script: &str) -> ProcessSpec {
        ProcessSpec {
            name: name.into(),
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: vec![("CC_TEST".into(), "hello".into())],
            cwd: None,
            log_file: None,
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn crashing_process_is_restarted_then_marked_failed() {
        let h = spawn_supervised(sh("crashy", "echo boom $CC_TEST; exit 3"), fast_policy(Some(3)), true);
        let failed = h.wait_for(Duration::from_secs(10), |s| matches!(s, ProcState::Failed { .. })).await;
        assert!(failed, "state: {:?}", h.state());
        assert_eq!(h.restarts(), 3);
        let logs = h.logs(100);
        assert!(logs.iter().filter(|l| l.as_str() == "boom hello").count() >= 3, "{logs:?}");
        assert!(logs.iter().any(|l| l.contains("exit status: 3")), "{logs:?}");
        // Explicit start clears the failure.
        h.start();
        assert!(h.wait_for(Duration::from_secs(5), |s| !matches!(s, ProcState::Failed { .. })).await);
        h.stop();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stop_and_restart_long_running_process() {
        let h = spawn_supervised(sh("sleeper", "echo up; exec sleep 30"), fast_policy(None), true);
        assert!(h.wait_for(Duration::from_secs(5), |s| matches!(s, ProcState::Running { .. })).await);
        let ProcState::Running { pid: pid1, .. } = h.state() else { unreachable!() };
        h.restart();
        assert!(
            h.wait_for(Duration::from_secs(15), |s| matches!(s, ProcState::Running { pid, .. } if *pid != pid1)).await,
            "{:?}",
            h.state()
        );
        assert_eq!(h.restarts(), 1);
        h.stop();
        assert!(h.wait_for(Duration::from_secs(15), |s| *s == ProcState::Stopped).await);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn not_autostarted_until_start() {
        let h = spawn_supervised(sh("lazy", "exec sleep 30"), fast_policy(None), false);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(h.state(), ProcState::Stopped);
        h.start();
        assert!(h.wait_for(Duration::from_secs(5), |s| matches!(s, ProcState::Running { .. })).await);
        h.stop();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn missing_binary_backs_off() {
        let mut spec = sh("missing", "");
        spec.program = "/nonexistent/binary".into();
        let h = spawn_supervised(spec, fast_policy(Some(2)), true);
        assert!(h.wait_for(Duration::from_secs(5), |s| matches!(s, ProcState::Failed { reason } if reason.contains("spawn failed"))).await, "{:?}", h.state());
    }
}
