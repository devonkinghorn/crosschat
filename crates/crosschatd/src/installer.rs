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

/// Where a manifest's binary is (or will be) installed.
pub fn install_path(manifest: &Manifest, bin_root: &Path) -> PathBuf {
    let version = match &manifest.source {
        Source::GithubRelease { version, .. } => version.clone(),
        Source::GoBuild { rev, .. } => rev.chars().take(12).collect(),
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
    let target = install_path(manifest, bin_root);
    if target.exists() {
        return Ok(target);
    }
    match &manifest.source {
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
            info!(bridge = manifest.id, rev, "building from source with go");
            run("go", &args, Some(&src)).await?;
            std::fs::rename(&tmp, &target)?;
        }
    }
    Ok(target)
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
