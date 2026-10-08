//! Sign-in flows crosschatd serves itself, for bridges without a bridgev2
//! provisioning API (`framework: legacy` + `local_setup` in the manifest).
//!
//! The app talks to them exactly like a bridgev2 bridge (`GET v3/whoami`,
//! `GET v3/login/flows`, `POST v3/login/start/<flow>`, `POST
//! v3/login/step/...`, `POST v3/logout/...`), so the generic login dialog
//! works unchanged. The bridge process only starts once the flow completes
//! (a marker file in its data dir); until then the network is listed as
//! `awaiting_setup`.
//!
//! `mac-messages` (mautrix-imessage's `mac` connector) needs two macOS
//! privacy permissions, which only the user can grant. They belong to the
//! Crosschat app: crosschatd and the bridge run as its child processes, so
//! macOS attributes their access to it.
//!   1. Full Disk Access, to read `~/Library/Messages/chat.db`. Checked with
//!      the bridge's own `--check-permissions` (exit 0 ok, 41 Messages not
//!      signed in, 42 no chat.db, 43 permission denied). macOS never prompts
//!      for it; the user turns it on in System Settings.
//!   2. Automation (Apple Events to Messages), to send. Checked by asking
//!      Messages for its name with `osascript`, which makes macOS show its
//!      "Crosschat wants access to control Messages" prompt the first time.
//!      Error -1743 means the user said no (fixable in System Settings).

use crate::bridge::BridgeRuntime;
use crate::manifest::{LocalSetup, Manifest};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const MARKER: &str = "crosschat-setup-complete";
pub const LOGIN_ID: &str = "mac";
pub const FLOW_ID: &str = "mac";

pub const FDA_SETTINGS: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";
pub const AUTOMATION_SETTINGS: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation";

pub fn marker_path(data_dir: &Path) -> PathBuf {
    data_dir.join(MARKER)
}

/// The user finished the sign-in flow (and hasn't signed out since).
pub fn is_set_up(data_dir: &Path) -> bool {
    marker_path(data_dir).is_file()
}

/// `mautrix-imessage --check-permissions`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiskAccess {
    Ok,
    /// 41: chat.db is readable but Messages isn't signed in (no accounts).
    NotSignedIn,
    /// 42: there's no chat.db (Messages was never set up on this Mac).
    NoChatDb,
    /// 43: Full Disk Access is off.
    Denied,
    Other(String),
}

/// `osascript` talking to Messages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Automation {
    Ok,
    /// -1743: not allowed to control Messages.
    Denied,
    Other(String),
}

/// `osascript` (`$CROSSCHAT_OSASCRIPT` overrides it, for tests).
pub fn osascript() -> PathBuf {
    std::env::var_os("CROSSCHAT_OSASCRIPT")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/usr/bin/osascript"))
}

pub async fn check_disk_access(binary: &Path) -> DiskAccess {
    let out = tokio::time::timeout(
        Duration::from_secs(30),
        tokio::process::Command::new(binary)
            .arg("--check-permissions")
            .stdin(std::process::Stdio::null())
            .output(),
    )
    .await;
    let out = match out {
        Err(_) => return DiskAccess::Other("the permission check timed out".into()),
        Ok(Err(e)) => return DiskAccess::Other(format!("couldn't run {}: {e}", binary.display())),
        Ok(Ok(o)) => o,
    };
    match out.status.code() {
        Some(0) => DiskAccess::Ok,
        Some(41) => DiskAccess::NotSignedIn,
        Some(42) => DiskAccess::NoChatDb,
        Some(43) => DiskAccess::Denied,
        code => {
            let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
            DiskAccess::Other(format!(
                "permission check failed ({}){}",
                code.map_or("signal".into(), |c| format!("exit {c}")),
                if text.is_empty() {
                    String::new()
                } else {
                    format!(": {text}")
                }
            ))
        }
    }
}

/// Ask Messages for its name. The first time, macOS asks the user whether
/// Crosschat may control Messages; this waits for the answer.
pub async fn check_automation(osascript: &Path) -> Automation {
    let out = tokio::time::timeout(
        Duration::from_secs(180),
        tokio::process::Command::new(osascript)
            .args([
                "-e",
                "tell application id \"com.apple.MobileSMS\" to get name",
            ])
            .stdin(std::process::Stdio::null())
            .output(),
    )
    .await;
    match out {
        Err(_) => Automation::Other("macOS didn't answer in time; try again".into()),
        Ok(Err(e)) => Automation::Other(format!("couldn't run osascript: {e}")),
        Ok(Ok(o)) if o.status.success() => Automation::Ok,
        Ok(Ok(o)) => {
            let err = String::from_utf8_lossy(&o.stderr).trim().to_string();
            if err.contains("-1743") || err.contains("Not authorized") {
                Automation::Denied
            } else {
                Automation::Other(err)
            }
        }
    }
}

/// Why the bridge can't run right now (shown as the account's status), or
/// `None` when it can. Run before starting it: without Full Disk Access the
/// bridge would exit at once and be restarted over and over.
pub async fn start_problem(m: &Manifest, binary: &Path) -> Option<String> {
    match m.local_setup? {
        LocalSetup::MacMessages => match check_disk_access(binary).await {
            DiskAccess::Ok => None,
            DiskAccess::Denied => Some(
                "Crosschat no longer has Full Disk Access, so it can't read your messages. Sign in again to fix it."
                    .into(),
            ),
            DiskAccess::NotSignedIn | DiskAccess::NoChatDb => {
                Some("Messages on this Mac isn't signed in to iMessage. Open Messages and sign in.".into())
            }
            DiskAccess::Other(e) => Some(e),
        },
    }
}

fn step_input(step_id: &str, instructions: &str, links: Value) -> Value {
    json!({
        "type": "user_input",
        "login_id": LOGIN_ID,
        "step_id": step_id,
        "instructions": instructions,
        "user_input": {"fields": []},
        // Crosschat extension: buttons the app shows under the instructions.
        "links": links,
    })
}

pub fn fda_step() -> Value {
    step_input(
        "app.crosschat.mac.full_disk_access",
        "Crosschat needs Full Disk Access to read your messages from the Messages app.\n\n\
         1. Open System Settings → Privacy & Security → Full Disk Access.\n\
         2. Turn on Crosschat. If it isn't listed, click +, choose Crosschat in Applications and turn it on.\n\
         3. If macOS offers to quit and reopen Crosschat, choose Later.\n\
         4. Come back here and click Continue.\n\n\
         Crosschat only reads your messages on this Mac; nothing changes in your security settings (SIP stays on).",
        json!([{"title": "Open Full Disk Access settings", "url": FDA_SETTINGS}]),
    )
}

pub fn messages_step(no_db: bool) -> Value {
    step_input(
        "app.crosschat.mac.messages",
        if no_db {
            "Messages hasn't been set up on this Mac yet. Open Messages, sign in with your Apple ID and turn on iMessage, then click Continue."
        } else {
            "Messages on this Mac isn't signed in. Open Messages → Settings → iMessage, sign in and wait for your conversations to appear, then click Continue."
        },
        json!([{"title": "Open Messages", "url": "file:///System/Applications/Messages.app"}]),
    )
}

pub fn automation_step(denied: bool) -> Value {
    step_input(
        "app.crosschat.mac.automation",
        if denied {
            "Crosschat isn't allowed to control Messages, so it can't send.\n\n\
             Open System Settings → Privacy & Security → Automation, expand Crosschat and turn on Messages, then click Continue."
        } else {
            "To send messages Crosschat uses the Messages app, so macOS asks once: \
             \"Crosschat wants access to control Messages\".\n\n\
             Click Continue, then click OK (or Allow) in that prompt. Messages opens if it isn't running."
        },
        json!([{"title": "Open Automation settings", "url": AUTOMATION_SETTINGS}]),
    )
}

pub fn complete_step() -> Value {
    json!({
        "type": "complete",
        "login_id": LOGIN_ID,
        "step_id": "app.crosschat.mac.complete",
        "instructions": "Connected to Messages on this Mac.",
        "complete": {"user_login_id": LOGIN_ID},
    })
}

/// The account's bridgev2-style state for `GET v3/whoami`.
pub fn login_state(rt: &BridgeRuntime, problem: Option<String>) -> Value {
    use crate::supervisor::ProcState;
    if let Some(p) = problem {
        return json!({"state_event": "BAD_CREDENTIALS", "error": "mac-permissions", "message": p});
    }
    match rt.proc_state() {
        ProcState::Running { .. } if rt.health.lock().unwrap().live == Some(true) => {
            json!({"state_event": "CONNECTED"})
        }
        ProcState::Running { .. } | ProcState::Starting | ProcState::Stopped => {
            json!({"state_event": "CONNECTING"})
        }
        ProcState::Backoff { last_exit, .. } => json!({
            "state_event": "UNKNOWN_ERROR",
            "message": format!("The bridge stopped ({last_exit}); restarting"),
        }),
        ProcState::Failed { reason } => json!({"state_event": "UNKNOWN_ERROR", "message": reason}),
    }
}

/// `GET v3/whoami` for a local-setup bridge.
pub fn whoami(m: &Manifest, server_name: &str, logins: Vec<Value>) -> Value {
    json!({
        "network": {
            "displayname": m.display_name,
            "network_id": m.network,
            "network_url": m.homepage,
        },
        "login_flows": login_flows(m)["flows"],
        "homeserver": server_name,
        "bridge_bot": format!("@{}:{server_name}", m.registration.bot_username),
        "command_prefix": "!im",
        "management_room": Value::Null,
        "logins": logins,
    })
}

pub fn login_flows(m: &Manifest) -> Value {
    match m.local_setup {
        Some(LocalSetup::MacMessages) | None => json!({"flows": [{
            "id": FLOW_ID,
            "name": "Messages on this Mac",
            "description": "Uses the Messages app on this Mac. You'll allow Full Disk Access and control of Messages; no Apple ID sign-in.",
        }]}),
    }
}

pub fn login_json(rt: &BridgeRuntime, problem: Option<String>) -> Value {
    json!({
        "id": LOGIN_ID,
        "name": "Messages on this Mac",
        "profile": {"name": "Messages on this Mac"},
        "state": login_state(rt, problem),
    })
}

/// Next step of the Mac Messages flow. `submitted` is the step the user just
/// confirmed: the Automation check (which may show macOS's prompt) only runs
/// once they've read the explanation and clicked Continue.
pub async fn next_mac_step(
    binary: &Path,
    osascript: &Path,
    submitted: Option<&str>,
) -> Result<Value, String> {
    match check_disk_access(binary).await {
        DiskAccess::Ok => {}
        DiskAccess::Denied => return Ok(fda_step()),
        DiskAccess::NotSignedIn => return Ok(messages_step(false)),
        DiskAccess::NoChatDb => return Ok(messages_step(true)),
        DiskAccess::Other(e) => return Err(e),
    }
    if submitted != Some("app.crosschat.mac.automation") {
        return Ok(automation_step(false));
    }
    match check_automation(osascript).await {
        Automation::Ok => Ok(complete_step()),
        Automation::Denied => Ok(automation_step(true)),
        Automation::Other(e) => Err(format!("Couldn't talk to Messages: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for `mautrix-imessage --check-permissions` exiting with `code`.
    pub(crate) fn fake_binary(dir: &Path, code: i32) -> PathBuf {
        let p = dir.join(format!("fake-imessage-{code}"));
        std::fs::write(&p, format!("#!/bin/sh\necho checked\nexit {code}\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        p
    }

    #[tokio::test]
    async fn disk_access_exit_codes() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(
            check_disk_access(&fake_binary(d.path(), 0)).await,
            DiskAccess::Ok
        );
        assert_eq!(
            check_disk_access(&fake_binary(d.path(), 41)).await,
            DiskAccess::NotSignedIn
        );
        assert_eq!(
            check_disk_access(&fake_binary(d.path(), 42)).await,
            DiskAccess::NoChatDb
        );
        assert_eq!(
            check_disk_access(&fake_binary(d.path(), 43)).await,
            DiskAccess::Denied
        );
        match check_disk_access(&fake_binary(d.path(), 49)).await {
            DiskAccess::Other(e) => assert!(e.contains("exit 49") && e.contains("checked"), "{e}"),
            other => panic!("{other:?}"),
        }
        assert!(matches!(
            check_disk_access(&d.path().join("missing")).await,
            DiskAccess::Other(_)
        ));
    }

    fn fake_osascript(dir: &Path, ok: bool) -> PathBuf {
        let p = dir.join(format!("osascript-{ok}"));
        let body = if ok {
            "#!/bin/sh\necho Messages\n".to_string()
        } else {
            "#!/bin/sh\necho \"execution error: Not authorized to send Apple events to Messages. (-1743)\" >&2\nexit 1\n".to_string()
        };
        std::fs::write(&p, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        p
    }

    #[tokio::test]
    async fn mac_flow_order() {
        let d = tempfile::tempdir().unwrap();
        let (yes, no) = (
            fake_osascript(d.path(), true),
            fake_osascript(d.path(), false),
        );
        let step = |code, osa: &PathBuf, sub: Option<&'static str>| {
            let (b, osa) = (fake_binary(d.path(), code), osa.clone());
            async move {
                next_mac_step(&b, &osa, sub).await.unwrap()["step_id"]
                    .as_str()
                    .unwrap()
                    .to_string()
            }
        };
        // Full Disk Access first, then Messages signed in, then Automation.
        assert_eq!(
            step(43, &yes, None).await,
            "app.crosschat.mac.full_disk_access"
        );
        assert_eq!(
            step(41, &yes, Some("app.crosschat.mac.full_disk_access")).await,
            "app.crosschat.mac.messages"
        );
        // The Automation prompt only fires after its explanation was confirmed.
        assert_eq!(
            step(0, &yes, Some("app.crosschat.mac.full_disk_access")).await,
            "app.crosschat.mac.automation"
        );
        assert_eq!(
            step(0, &yes, Some("app.crosschat.mac.automation")).await,
            "app.crosschat.mac.complete"
        );
        let denied = next_mac_step(
            &fake_binary(d.path(), 0),
            &no,
            Some("app.crosschat.mac.automation"),
        )
        .await
        .unwrap();
        assert_eq!(denied["step_id"], "app.crosschat.mac.automation");
        assert!(
            denied["instructions"]
                .as_str()
                .unwrap()
                .contains("isn't allowed")
        );
        assert!(
            next_mac_step(&fake_binary(d.path(), 49), &yes, None)
                .await
                .is_err()
        );
    }

    #[test]
    fn steps_have_links_and_no_fields() {
        for s in [
            fda_step(),
            messages_step(true),
            automation_step(false),
            automation_step(true),
        ] {
            assert_eq!(s["type"], "user_input");
            assert_eq!(s["user_input"]["fields"], json!([]));
            assert!(s["links"][0]["url"].as_str().is_some(), "{s}");
            assert_eq!(s["login_id"], LOGIN_ID);
        }
        assert_eq!(fda_step()["links"][0]["url"], FDA_SETTINGS);
        assert!(
            automation_step(true)["instructions"]
                .as_str()
                .unwrap()
                .contains("Automation")
        );
        assert_eq!(complete_step()["complete"]["user_login_id"], LOGIN_ID);
    }
}
