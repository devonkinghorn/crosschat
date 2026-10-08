//! Bridge manifests (`manifests/*.yaml`, schema `crosschat.bridge/v1`).
//!
//! A manifest tells crosschatd how to obtain an *unmodified* upstream bridge
//! binary, how to run it, which config keys Crosschat manages, and what the UI
//! needs to know (capabilities, preflight warnings, platform requirements).
//! Bridge code is never vendored: prebuilt binaries are fetched at install
//! time, from upstream's release or, where upstream has no usable binary for
//! a platform, from Crosschat's `prebuilt-vN` release (built from unmodified
//! upstream source by `scripts/build-prebuilt.sh`). Every artifact must have
//! a pinned checksum; users never compile anything.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::LazyLock;

pub const SCHEMA_V1: &str = "crosschat.bridge/v1";

/// Platform keys accepted in `source.artifacts`.
pub const PLATFORMS: &[&str] = &[
    "linux-amd64",
    "linux-arm64",
    "linux-armv7",
    "darwin-arm64",
    "darwin-amd64",
    "darwin-universal",
];

static ID_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z][a-z0-9_-]{1,31}$").unwrap());
static LOCALPART_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9._=/+-]+$").unwrap());

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: String,
    pub id: String,
    pub display_name: String,
    /// Network id the UI groups rooms by (matches `m.bridge` protocol id).
    pub network: String,
    #[serde(default)]
    pub description: String,
    pub framework: Framework,
    /// SPDX license of the upstream bridge (informational; never vendored).
    pub license: String,
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub maturity: Maturity,
    /// Host OSes the bridge can run on (`linux`, `macos`).
    pub host_platforms: Vec<String>,
    pub source: Source,
    /// Per-platform replacement for `source` (e.g. Crosschat's prebuilt
    /// macOS binary when upstream's links a library users can't get).
    #[serde(default)]
    pub source_overrides: BTreeMap<String, Source>,
    pub process: ProcessSpec,
    pub registration: RegistrationSpec,
    /// Network-specific config, deep-merged over the bridge's example config.
    /// Crosschat-managed keys (tokens, ports, homeserver) are applied after.
    #[serde(default)]
    pub config: serde_yaml_ng::Value,
    #[serde(default)]
    pub login: LoginSpec,
    #[serde(default)]
    pub capabilities: Capabilities,
    #[serde(default)]
    pub preflight: Vec<Preflight>,
    #[serde(default)]
    pub requirements: Vec<Requirement>,
    #[serde(default)]
    pub health: HealthSpec,
    /// Keep the host from idle-sleeping while the bridge runs (macOS
    /// `caffeinate -i`): bridges that hold a live connection to the network
    /// on this machine, like iMessage, miss messages while it sleeps.
    #[serde(default)]
    pub keep_awake: bool,
    /// How the bridge wants phone numbers / emails in `resolve_identifier`
    /// and `create_dm`, e.g. iMessage: `{phone: "tel:", email: "mailto:"}`.
    /// Without an entry the plain `+15551234567` / `a@b.c` is passed.
    #[serde(default)]
    pub identifier_prefixes: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Framework {
    Bridgev2,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Maturity {
    #[default]
    Stable,
    Beta,
    Alpha,
    Experimental,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Source {
    /// Prebuilt binaries attached to a GitHub release.
    GithubRelease {
        repo: String,
        version: String,
        artifacts: BTreeMap<String, String>,
        /// Name of a `sha256sum`-style file in the same release.
        #[serde(default)]
        checksums: Option<String>,
        /// Pinned hashes per platform, for releases without a checksum file.
        #[serde(default)]
        sha256: BTreeMap<String, String>,
    },
    /// Build from source with the Go toolchain. Developer option only: it
    /// runs when `CROSSCHAT_ALLOW_SOURCE_BUILDS=1`, never for end users.
    GoBuild {
        repo: String,
        rev: String,
        package: String,
        #[serde(default)]
        tags: Vec<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProcessSpec {
    /// File name of the installed binary.
    pub binary: String,
    /// Arguments; `{{config}}`, `{{registration}}`, `{{data_dir}}` available.
    pub args: Vec<String>,
    /// Arguments that make the bridge write its example config to `{{config}}`.
    #[serde(default)]
    pub generate_example_config: Option<Vec<String>>,
    /// Upstream default appservice port (used if free).
    pub default_port: u16,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RegistrationSpec {
    pub bot_username: String,
    /// Go template for ghost localparts, e.g. `gmessages_{{.}}`.
    pub username_template: String,
    #[serde(default = "yes")]
    pub ephemeral_events: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct LoginSpec {
    /// UI hints per bridgev2 login flow id. The authoritative list comes from
    /// `GET /v3/login/flows` at runtime.
    #[serde(default)]
    pub flows: Vec<LoginFlowHint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct LoginFlowHint {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub help: String,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Support {
    Yes,
    No,
    #[default]
    Unknown,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    #[serde(default)]
    pub threads: Support,
    #[serde(default)]
    pub replies: Support,
    #[serde(default)]
    pub reactions: Support,
    #[serde(default)]
    pub edits: Support,
    #[serde(default)]
    pub contacts: Support,
    #[serde(default)]
    pub search_users: Support,
    #[serde(default)]
    pub create_group: Support,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Info,
    Warning,
    Blocking,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Preflight {
    pub id: String,
    pub severity: Severity,
    pub message: String,
    #[serde(default)]
    pub link: Option<String>,
    /// Host OSes this applies to (empty = all).
    #[serde(default)]
    pub when_host: Vec<String>,
    /// The app asks the user to tick it off before signing in.
    #[serde(default)]
    pub confirm: bool,
}

/// Something the user must supply that only certain *client* platforms can
/// produce, e.g. the iMessage hardware key extracted by the macOS app.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Requirement {
    pub id: String,
    pub description: String,
    /// Host OSes on which this requirement applies (empty = all).
    #[serde(default)]
    pub when_host: Vec<String>,
    /// Client platforms able to provide it (capability flag in the app).
    pub provided_by: Vec<String>,
    /// Login field the value is submitted into, if any.
    #[serde(default)]
    pub login_field: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HealthSpec {
    #[serde(default = "default_live")]
    pub liveness: String,
    #[serde(default = "default_ready")]
    pub readiness: String,
    #[serde(default = "default_interval")]
    pub interval_secs: u64,
    #[serde(default = "default_failures")]
    pub failures_before_restart: u32,
}

fn default_live() -> String {
    "/_matrix/mau/live".into()
}
fn default_ready() -> String {
    "/_matrix/mau/ready".into()
}
fn default_interval() -> u64 {
    15
}
fn default_failures() -> u32 {
    4
}

impl Default for HealthSpec {
    fn default() -> Self {
        Self {
            liveness: default_live(),
            readiness: default_ready(),
            interval_secs: default_interval(),
            failures_before_restart: default_failures(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("io error reading {path}: {source}")]
    Io {
        path: String,
        source: std::io::Error,
    },
    #[error("parse error in {path}: {source}")]
    Parse {
        path: String,
        source: serde_yaml_ng::Error,
    },
    #[error("invalid manifest {id}: {problems:?}")]
    Invalid { id: String, problems: Vec<String> },
}

/// The platform key for the machine we're running on.
pub fn current_platform() -> String {
    let os = match std::env::consts::OS {
        "macos" => "darwin",
        other => other,
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        "arm" => "armv7",
        other => other,
    };
    format!("{os}-{arch}")
}

pub fn current_host_os() -> &'static str {
    std::env::consts::OS
}

fn validate_source(src: &Source, at: &str, p: &mut Vec<String>) {
    match src {
        Source::GithubRelease {
            repo,
            version,
            artifacts,
            sha256,
            checksums,
        } => {
            if repo.split('/').count() != 2 {
                p.push(format!("{at}.repo `{repo}` must be `owner/name`"));
            }
            if version.trim().is_empty() {
                p.push(format!("{at}.version is empty"));
            }
            if artifacts.is_empty() {
                p.push(format!("{at}.artifacts is empty"));
            }
            for k in artifacts.keys().chain(sha256.keys()) {
                if !PLATFORMS.contains(&k.as_str()) {
                    p.push(format!("unknown artifact platform `{k}`"));
                }
            }
            for (k, h) in sha256 {
                if h.len() != 64 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
                    p.push(format!("{at}.sha256.{k} must be a 64-digit hex SHA-256"));
                }
            }
            if checksums.is_none() {
                for k in artifacts.keys().filter(|k| !sha256.contains_key(*k)) {
                    p.push(format!(
                        "{at}.artifacts.{k} has no pinned checksum (add {at}.sha256.{k} or a checksums file)"
                    ));
                }
            }
        }
        Source::GoBuild {
            repo, rev, package, ..
        } => {
            if !repo.starts_with("https://") {
                p.push(format!("{at}.repo for go-build must be an https git URL"));
            }
            if rev.len() < 7 {
                p.push(format!("{at}.rev must pin a commit or tag"));
            }
            if !package.starts_with("./") {
                p.push(format!(
                    "{at}.package must be a relative Go package path like ./cmd/x"
                ));
            }
        }
    }
}

impl Manifest {
    pub fn from_yaml(text: &str, path: &str) -> Result<Self, ManifestError> {
        let m: Manifest = serde_yaml_ng::from_str(text).map_err(|source| ManifestError::Parse {
            path: path.to_string(),
            source,
        })?;
        let problems = m.validate();
        if problems.is_empty() {
            Ok(m)
        } else {
            Err(ManifestError::Invalid {
                id: m.id.clone(),
                problems,
            })
        }
    }

    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let text = std::fs::read_to_string(path).map_err(|source| ManifestError::Io {
            path: path.display().to_string(),
            source,
        })?;
        Self::from_yaml(&text, &path.display().to_string())
    }

    /// Load every `*.yaml` / `*.yml` manifest in a directory, sorted by id.
    pub fn load_dir(dir: &Path) -> Result<Vec<Self>, ManifestError> {
        let rd = std::fs::read_dir(dir).map_err(|source| ManifestError::Io {
            path: dir.display().to_string(),
            source,
        })?;
        let mut out = Vec::new();
        for entry in rd.flatten() {
            let p = entry.path();
            if matches!(p.extension().and_then(|e| e.to_str()), Some("yaml" | "yml")) {
                out.push(Self::load(&p)?);
            }
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(out)
    }

    /// Returns a list of human-readable problems (empty = valid).
    pub fn validate(&self) -> Vec<String> {
        let mut p = Vec::new();
        if self.schema != SCHEMA_V1 {
            p.push(format!(
                "schema must be `{SCHEMA_V1}`, got `{}`",
                self.schema
            ));
        }
        if !ID_RE.is_match(&self.id) {
            p.push(format!("id `{}` must match {}", self.id, ID_RE.as_str()));
        }
        if self.display_name.trim().is_empty() {
            p.push("display_name is empty".into());
        }
        if self.network.trim().is_empty() {
            p.push("network is empty".into());
        }
        if self.host_platforms.is_empty() {
            p.push("host_platforms is empty".into());
        }
        for hp in &self.host_platforms {
            if !matches!(hp.as_str(), "linux" | "macos") {
                p.push(format!("unknown host platform `{hp}`"));
            }
        }
        validate_source(&self.source, "source", &mut p);
        for (platform, src) in &self.source_overrides {
            if !PLATFORMS.contains(&platform.as_str()) {
                p.push(format!("unknown source_overrides platform `{platform}`"));
            }
            validate_source(src, &format!("source_overrides.{platform}"), &mut p);
        }
        if self.process.binary.is_empty() || self.process.binary.contains('/') {
            p.push("process.binary must be a plain file name".into());
        }
        if !self.process.args.iter().any(|a| a.contains("{{config}}")) {
            p.push("process.args must reference {{config}}".into());
        }
        if self.process.default_port == 0 {
            p.push("process.default_port must be non-zero".into());
        }
        let r = &self.registration;
        if !LOCALPART_RE.is_match(&r.bot_username) {
            p.push(format!(
                "registration.bot_username `{}` is not a valid localpart",
                r.bot_username
            ));
        }
        if r.username_template.matches("{{.}}").count() != 1 {
            p.push("registration.username_template must contain `{{.}}` exactly once".into());
        } else {
            let (pre, _) = r.username_template.split_once("{{.}}").unwrap();
            if pre.is_empty() {
                p.push("registration.username_template needs a prefix before `{{.}}` (namespace would be too broad)".into());
            }
        }
        if !self.config.is_null() && !self.config.is_mapping() {
            p.push("config must be a mapping".into());
        }
        for req in &self.requirements {
            if req.provided_by.is_empty() {
                p.push(format!(
                    "requirement `{}` has no provided_by platforms",
                    req.id
                ));
            }
        }
        p
    }

    /// Artifact file name for a platform key, falling back to a macOS
    /// universal binary on any darwin architecture.
    pub fn artifact_for(&self, platform: &str) -> Option<&str> {
        let Source::GithubRelease { artifacts, .. } = self.source_for(platform) else {
            return None;
        };
        artifacts
            .get(platform)
            .or_else(|| {
                platform
                    .starts_with("darwin-")
                    .then(|| artifacts.get("darwin-universal"))
                    .flatten()
            })
            .map(String::as_str)
    }

    /// Pinned SHA-256 of [`Self::artifact_for`]'s file, with the same
    /// darwin-universal fallback.
    pub fn sha256_for(&self, platform: &str) -> Option<&str> {
        let Source::GithubRelease { sha256, .. } = self.source_for(platform) else {
            return None;
        };
        sha256
            .get(platform)
            .or_else(|| {
                platform
                    .starts_with("darwin-")
                    .then(|| sha256.get("darwin-universal"))
                    .flatten()
            })
            .map(String::as_str)
    }

    /// The install source for a platform key (`source_overrides`, falling
    /// back to `source`).
    pub fn source_for(&self, platform: &str) -> &Source {
        self.source_overrides.get(platform).unwrap_or(&self.source)
    }

    pub fn supports_host(&self, host_os: &str) -> bool {
        self.host_platforms.iter().any(|h| h == host_os)
    }

    /// A phone number or email as this bridge expects it: formatting
    /// stripped (`+1 (555) 123-4567` → `+15551234567`), emails lowercased,
    /// plus the manifest's prefix (`tel:` / `mailto:`). Anything else is
    /// returned trimmed.
    pub fn network_identifier(&self, q: &str) -> String {
        let q = q.trim();
        let (kind, bare) = if let Some(e) = q.strip_prefix("mailto:") {
            ("email", e.to_lowercase())
        } else if let Some(t) = q.strip_prefix("tel:") {
            ("phone", t.to_string())
        } else if q.contains('@') && !q.starts_with('@') {
            ("email", q.to_lowercase())
        } else if q.starts_with('+')
            && q.chars()
                .all(|c| c.is_ascii_digit() || " +-().".contains(c))
        {
            (
                "phone",
                q.chars()
                    .filter(|c| c.is_ascii_digit() || *c == '+')
                    .collect(),
            )
        } else {
            return q.to_string();
        };
        match self.identifier_prefixes.get(kind) {
            Some(prefix) => format!("{prefix}{bare}"),
            None => bare,
        }
    }

    /// Pre-login checklist items that apply when the bridge runs on `host_os`.
    pub fn preflight_for_host(&self, host_os: &str) -> Vec<&Preflight> {
        self.preflight
            .iter()
            .filter(|p| p.when_host.is_empty() || p.when_host.iter().any(|h| h == host_os))
            .collect()
    }

    /// Requirements that apply when the bridge runs on `host_os`.
    pub fn requirements_for_host(&self, host_os: &str) -> Vec<&Requirement> {
        self.requirements
            .iter()
            .filter(|r| r.when_host.is_empty() || r.when_host.iter().any(|h| h == host_os))
            .collect()
    }

    pub fn ghost_prefix(&self) -> &str {
        self.registration
            .username_template
            .split("{{.}}")
            .next()
            .unwrap_or("")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str = r#"
schema: crosschat.bridge/v1
id: gmessages
display_name: Google Messages
network: gmessages
framework: bridgev2
license: AGPL-3.0
host_platforms: [linux, macos]
source:
  kind: github-release
  repo: mautrix/gmessages
  version: v0.2609.0
  checksums: sha256sums.txt
  artifacts:
    linux-amd64: mautrix-gmessages-amd64
    darwin-arm64: mautrix-gmessages-darwin-arm64
process:
  binary: mautrix-gmessages
  args: ["-c", "{{config}}", "-r", "{{registration}}"]
  default_port: 29336
registration:
  bot_username: gmessagesbot
  username_template: "gmessages_{{.}}"
capabilities:
  threads: no
requirements:
  - id: hw_key
    description: test
    when_host: [linux]
    provided_by: [macos]
"#;

    #[test]
    fn imessage_manifest_checklist_and_identifiers() {
        let m = Manifest::from_yaml(
            include_str!("../../../manifests/imessage.yaml"),
            "imessage.yaml",
        )
        .unwrap();
        assert!(m.keep_awake);
        let mac: Vec<&str> = m
            .preflight_for_host("macos")
            .iter()
            .map(|p| p.id.as_str())
            .collect();
        assert!(mac.contains(&"contact_key_verification"));
        assert!(mac.contains(&"stay_awake"));
        let linux: Vec<&str> = m
            .preflight_for_host("linux")
            .iter()
            .map(|p| p.id.as_str())
            .collect();
        assert!(!linux.contains(&"stay_awake"));
        let confirm: Vec<&str> = m
            .preflight
            .iter()
            .filter(|p| p.confirm)
            .map(|p| p.id.as_str())
            .collect();
        assert_eq!(confirm, ["contact_key_verification"]);
        assert!(m.requirements_for_host("macos").is_empty());
        assert_eq!(m.requirements_for_host("linux").len(), 1);
        assert_eq!(
            m.network_identifier(" +1 (555) 123-4567 "),
            "tel:+15551234567"
        );
        assert_eq!(
            m.network_identifier("Jess@Example.com"),
            "mailto:jess@example.com"
        );
        assert_eq!(m.network_identifier("tel:+15551234567"), "tel:+15551234567");
        // Without prefixes (Google Messages): just the cleaned-up number.
        let g = Manifest::from_yaml(GOOD, "t").unwrap();
        assert_eq!(g.network_identifier("+1 555-123-4567"), "+15551234567");
        assert_eq!(g.network_identifier("someone"), "someone");
    }

    #[test]
    fn parses_valid_manifest() {
        let m = Manifest::from_yaml(GOOD, "t").unwrap();
        assert_eq!(m.id, "gmessages");
        assert_eq!(m.capabilities.threads, Support::No);
        assert_eq!(m.capabilities.reactions, Support::Unknown);
        assert_eq!(m.health.liveness, "/_matrix/mau/live");
        assert_eq!(
            m.artifact_for("linux-amd64"),
            Some("mautrix-gmessages-amd64")
        );
        assert_eq!(m.artifact_for("linux-arm64"), None);
        assert_eq!(m.ghost_prefix(), "gmessages_");
        assert_eq!(m.requirements_for_host("linux").len(), 1);
        assert_eq!(m.requirements_for_host("macos").len(), 0);
        assert!(m.registration.ephemeral_events);
    }

    #[test]
    fn rejects_unknown_fields() {
        let bad = GOOD.replace("license: AGPL-3.0", "license: AGPL-3.0\nsurprise: 1");
        assert!(matches!(
            Manifest::from_yaml(&bad, "t"),
            Err(ManifestError::Parse { .. })
        ));
    }

    #[test]
    fn reports_validation_problems() {
        let bad = GOOD
            .replace("id: gmessages", "id: Bad ID")
            .replace("gmessages_{{.}}", "{{.}}")
            .replace("linux-amd64:", "windows-amd64:")
            .replace("\"{{config}}\"", "\"cfg.yaml\"");
        match Manifest::from_yaml(&bad, "t") {
            Err(ManifestError::Invalid { problems, .. }) => {
                let all = problems.join("\n");
                assert!(all.contains("id `Bad ID`"), "{all}");
                assert!(all.contains("prefix before"), "{all}");
                assert!(all.contains("windows-amd64"), "{all}");
                assert!(all.contains("{{config}}"), "{all}");
            }
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    #[test]
    fn darwin_universal_fallback() {
        let m = Manifest::from_yaml(
            &GOOD.replace(
                "darwin-arm64: mautrix-gmessages-darwin-arm64",
                "darwin-universal: uni",
            ),
            "t",
        )
        .unwrap();
        assert_eq!(m.artifact_for("darwin-arm64"), Some("uni"));
        assert_eq!(m.artifact_for("darwin-amd64"), Some("uni"));
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../manifests");
        let im = Manifest::load(&dir.join("imessage.yaml")).unwrap();
        assert_eq!(im.artifact_for("darwin-arm64"), Some("corten-matrix-macos"));
        assert_eq!(im.sha256_for("darwin-arm64"), im.sha256_for("darwin-amd64"));
        assert_eq!(im.sha256_for("darwin-arm64").map(str::len), Some(64));
        assert_eq!(im.sha256_for("linux-armv7"), None);
    }

    #[test]
    fn source_overrides_per_platform() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../manifests");
        for id in ["gmessages", "slack"] {
            let m = Manifest::load(&dir.join(format!("{id}.yaml"))).unwrap();
            // macOS uses Crosschat's goolm builds (upstream darwin binaries need libolm).
            for p in ["darwin-arm64", "darwin-amd64"] {
                match m.source_for(p) {
                    Source::GithubRelease { repo, sha256, .. } => {
                        assert_eq!(repo, PREBUILT_REPO, "{id} {p}");
                        assert!(sha256.contains_key(p), "{id} {p}");
                    }
                    other => panic!("{id} {p}: {other:?}"),
                }
                let a = m.artifact_for(p).unwrap();
                assert!(
                    a.starts_with(&format!("mautrix-{id}-")) && a.ends_with(&format!("-{p}.zst")),
                    "{a}"
                );
            }
            match m.source_for("linux-amd64") {
                Source::GithubRelease { repo, .. } => assert_eq!(repo, &format!("mautrix/{id}")),
                other => panic!("{other:?}"),
            }
            assert!(m.artifact_for("linux-amd64").is_some());
        }
        let bad = GOOD.replace(
            "process:\n",
            "source_overrides:\n  windows-amd64:\n    kind: go-build\n    repo: git@x\n    rev: abc\n    package: cmd\nprocess:\n",
        );
        match Manifest::from_yaml(&bad, "t") {
            Err(ManifestError::Invalid { problems, .. }) => {
                let all = problems.join("\n");
                assert!(
                    all.contains("unknown source_overrides platform `windows-amd64`"),
                    "{all}"
                );
                assert!(all.contains("source_overrides.windows-amd64.repo"), "{all}");
                assert!(all.contains("source_overrides.windows-amd64.rev"), "{all}");
            }
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    const PREBUILT_REPO: &str = "devonkinghorn/crosschat";

    #[test]
    fn every_artifact_needs_a_pinned_checksum() {
        let unpinned = GOOD.replace("  checksums: sha256sums.txt\n", "");
        match Manifest::from_yaml(&unpinned, "t") {
            Err(ManifestError::Invalid { problems, .. }) => {
                assert_eq!(problems.len(), 2, "{problems:?}");
                assert!(problems[0].contains("no pinned checksum"), "{problems:?}");
            }
            other => panic!("expected invalid, got {other:?}"),
        }
        let pinned = unpinned.replace(
            "  artifacts:\n",
            &format!(
                "  sha256:\n    linux-amd64: {a}\n    darwin-arm64: {a}\n  artifacts:\n",
                a = "a".repeat(64)
            ),
        );
        Manifest::from_yaml(&pinned, "t").unwrap();
        let short = GOOD.replace(
            "  checksums: sha256sums.txt\n",
            "  sha256:\n    linux-amd64: abc\n",
        );
        match Manifest::from_yaml(&short, "t") {
            Err(ManifestError::Invalid { problems, .. }) => {
                let all = problems.join("\n");
                assert!(
                    all.contains("source.sha256.linux-amd64 must be a 64-digit hex"),
                    "{all}"
                );
                assert!(
                    all.contains("source.artifacts.darwin-arm64 has no pinned checksum"),
                    "{all}"
                );
            }
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    /// Every artifact from Crosschat's own prebuilt release is listed in
    /// `prebuilt/SHA256SUMS` with the same hash, and no manifest builds from
    /// source on a platform a user can pick.
    #[test]
    fn prebuilt_pins_match_release_sums() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let sums = std::fs::read_to_string(root.join("prebuilt/SHA256SUMS")).unwrap();
        let all = Manifest::load_dir(&root.join("manifests")).unwrap();
        let mut checked = 0;
        for m in &all {
            for p in ["linux-amd64", "linux-arm64", "darwin-arm64", "darwin-amd64"] {
                match m.source_for(p) {
                    Source::GoBuild { .. } => panic!("{} builds from source on {p}", m.id),
                    Source::GithubRelease { repo, sha256, .. } if repo == PREBUILT_REPO => {
                        let a = m.artifact_for(p).unwrap_or_else(|| panic!("{} {p}", m.id));
                        assert_eq!(
                            crate::installer::parse_checksums(&sums, a).as_deref(),
                            sha256.get(p).map(String::as_str),
                            "{} {p} {a}",
                            m.id
                        );
                        checked += 1;
                    }
                    Source::GithubRelease { .. } => {}
                }
            }
        }
        assert_eq!(checked, 8, "gmessages+slack on darwin x2, groupme x4");
    }

    #[test]
    fn repo_manifests_are_valid() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../manifests");
        let all = Manifest::load_dir(&dir).expect("manifests/ should load and validate");
        let ids: Vec<_> = all.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["gmessages", "groupme", "imessage", "slack"]);
    }

    #[test]
    fn platform_key_shape() {
        let p = current_platform();
        assert!(p.contains('-'));
    }
}
