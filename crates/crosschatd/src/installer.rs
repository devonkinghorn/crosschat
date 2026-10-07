//! Fetches unmodified upstream bridge binaries at install time.
//! Nothing AGPL is vendored in this repository.

use crate::manifest::{Manifest, Source};
use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use tracing::{info, warn};

/// Find the hash for `file` in a `sha256sum`-style listing.
pub fn parse_checksums(text: &str, file: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let name = parts.next()?.trim_start_matches('*');
        let name = name.rsplit('/').next().unwrap_or(name);
        (name == file && hash.len() == 64).then(|| hash.to_ascii_lowercase())
    })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub fn release_url(repo: &str, version: &str, file: &str) -> String {
    format!("https://github.com/{repo}/releases/download/{version}/{file}")
}

/// Where a manifest's binary is (or will be) installed on `platform`.
pub fn install_path(manifest: &Manifest, bin_root: &Path, platform: &str) -> PathBuf {
    let version = match manifest.source_for(platform) {
        Source::GithubRelease { version, .. } => version.clone(),
        Source::GoBuild { rev, .. } => format!("src-{}", rev.chars().take(12).collect::<String>()),
    };
    bin_root
        .join(&manifest.id)
        .join(version)
        .join(&manifest.process.binary)
}

async fn download(http: &reqwest::Client, url: &str) -> Result<Vec<u8>> {
    let resp = http
        .get(url)
        .send()
        .await?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?;
    Ok(resp.bytes().await?.to_vec())
}

fn write_executable(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow!("bad install path"))?;
    std::fs::create_dir_all(dir)?;
    let tmp = path.with_extension("download");
    std::fs::write(&tmp, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&tmp, path)?; // atomic swap
    Ok(())
}

/// Ensure the bridge binary is installed for this platform and return its path.
pub async fn ensure_installed(
    manifest: &Manifest,
    bin_root: &Path,
    platform: &str,
    http: &reqwest::Client,
) -> Result<PathBuf> {
    let target = install_path(manifest, bin_root, platform);
    if target.exists() {
        return Ok(target);
    }
    match manifest.source_for(platform) {
        Source::GithubRelease {
            repo,
            version,
            checksums,
            sha256,
            ..
        } => {
            let artifact = manifest
                .artifact_for(platform)
                .ok_or_else(|| anyhow!("{} has no release artifact for {platform}", manifest.id))?;
            let url = release_url(repo, version, artifact);
            info!(bridge = manifest.id, %url, "downloading");
            let bytes = download(http, &url).await?;
            let actual = sha256_hex(&bytes);
            let expected = if let Some(file) = checksums {
                let listing =
                    String::from_utf8(download(http, &release_url(repo, version, file)).await?)?;
                Some(
                    parse_checksums(&listing, artifact)
                        .ok_or_else(|| anyhow!("{artifact} missing from {file}"))?,
                )
            } else {
                sha256.get(platform).map(|s| s.to_ascii_lowercase())
            };
            match expected {
                Some(exp) if exp != actual => {
                    bail!("checksum mismatch for {artifact}: expected {exp}, got {actual}")
                }
                Some(_) => info!(bridge = manifest.id, "checksum verified"),
                None => warn!(
                    bridge = manifest.id,
                    sha256 = actual,
                    "upstream publishes no checksums; recording hash (trust on first use)"
                ),
            }
            write_executable(&target, &bytes)?;
            std::fs::write(target.with_extension("sha256"), &actual)?;
        }
        Source::GoBuild {
            repo,
            rev,
            package,
            tags,
        } => {
            let dir = target.parent().unwrap().to_path_buf();
            let src = dir.join("src");
            std::fs::create_dir_all(&dir)?;
            if !src.exists() {
                run(
                    "git",
                    &["clone", "--filter=blob:none", repo, src.to_str().unwrap()],
                    None,
                )
                .await?;
            }
            run("git", &["checkout", "--detach", rev], Some(&src)).await?;
            let tmp = target.with_extension("build");
            let tag_arg = tags.join(",");
            let mut args = vec!["build"];
            if !tag_arg.is_empty() {
                args.extend(["-tags", &tag_arg]);
            }
            args.extend(["-o", tmp.to_str().unwrap(), package]);
            let go = find_go().ok_or_else(|| {
                anyhow!(
                    "{} is built from source on this platform and needs Go (e.g. `brew install go`)",
                    manifest.display_name
                )
            })?;
            info!(bridge = manifest.id, rev, go = %go.display(), "building from source with go");
            run_go(&go, &args, &src).await?;
            std::fs::rename(&tmp, &target)?;
        }
    }
    Ok(target)
}

/// Find `go`: `$GOROOT/bin`, Homebrew, the official installer location,
/// then `$PATH` (apps started from Finder get a minimal `$PATH`).
pub fn find_go() -> Option<PathBuf> {
    let mut c: Vec<PathBuf> = Vec::new();
    c.extend(std::env::var_os("GOROOT").map(|r| PathBuf::from(r).join("bin/go")));
    c.push("/opt/homebrew/bin/go".into());
    c.push("/usr/local/go/bin/go".into());
    c.push("/usr/local/bin/go".into());
    if let Some(path) = std::env::var_os("PATH") {
        c.extend(std::env::split_paths(&path).map(|d| d.join("go")));
    }
    c.into_iter().find(|p| p.is_file())
}

/// `go build` with Go's toolchain auto-download allowed (bridges pin newer
/// toolchains in go.mod) and, on macOS, Apple clang for cgo: `/usr/bin`
/// first on `PATH` and no `CC`/`CXX`/`AR` from Nix.
async fn run_go(go: &Path, args: &[&str], cwd: &Path) -> Result<()> {
    let mut cmd = tokio::process::Command::new(go);
    cmd.args(args).current_dir(cwd).env("GOTOOLCHAIN", "auto");
    if cfg!(target_os = "macos") {
        cmd.env(
            "PATH",
            crate::tuwunel::macos_build_path(go, std::env::var_os("PATH").as_deref()),
        )
        .env_remove("CC")
        .env_remove("CXX")
        .env_remove("AR");
    }
    let out = cmd
        .output()
        .await
        .with_context(|| format!("running {}", go.display()))?;
    if !out.status.success() {
        bail!(
            "go {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

async fn run(program: &str, args: &[&str], cwd: Option<&Path>) -> Result<()> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args);
    if let Some(c) = cwd {
        cmd.current_dir(c);
    }
    let out = cmd
        .output()
        .await
        .with_context(|| format!("running {program}"))?;
    if !out.status.success() {
        bail!(
            "{program} {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_listing() {
        let listing = "\
0f343b0931126a20f133d67c2b018a3b5bd2a6b47e1d8a7c2f1d66f3a2b4c5d6  mautrix-gmessages-amd64
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA *dist/mautrix-gmessages-arm64
";
        assert_eq!(
            parse_checksums(listing, "mautrix-gmessages-amd64").as_deref(),
            Some("0f343b0931126a20f133d67c2b018a3b5bd2a6b47e1d8a7c2f1d66f3a2b4c5d6")
        );
        assert_eq!(
            parse_checksums(listing, "mautrix-gmessages-arm64").unwrap(),
            "a".repeat(64)
        );
        assert_eq!(parse_checksums(listing, "mautrix-gmessages-arm"), None);
    }

    #[test]
    fn install_path_depends_on_platform_source() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../manifests");
        let m = Manifest::load(&dir.join("slack.yaml")).unwrap();
        let root = Path::new("/bin-root");
        assert_eq!(
            install_path(&m, root, "linux-amd64"),
            Path::new("/bin-root/slack/v0.2609.1/mautrix-slack")
        );
        assert_eq!(
            install_path(&m, root, "darwin-arm64"),
            Path::new("/bin-root/slack/src-v0.2609.1/mautrix-slack")
        );
    }

    #[test]
    fn sha_and_urls() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            release_url("mautrix/slack", "v1", "x"),
            "https://github.com/mautrix/slack/releases/download/v1/x"
        );
    }
}
