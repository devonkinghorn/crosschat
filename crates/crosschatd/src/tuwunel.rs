//! Finding (or installing) the Tuwunel homeserver binary for the bundled
//! homeserver.
//!
//! Resolution order (first hit wins):
//! 1. `TUWUNEL_BIN` environment variable (must point at an existing file).
//! 2. `homeserver.bundled.binary` in `crosschatd.toml`.
//! 3. A `tuwunel` file next to the running `crosschatd` executable (how a
//!    packaged app ships it).
//! 4. The pinned version in the Crosschat cache
//!    (`<cache>/tuwunel-<version>/bin/tuwunel`).
//! 5. Download the pinned version into the cache (SHA-256 pinned here,
//!    `.zst` unpacked in-process):
//!    * Linux: the upstream release.
//!    * macOS: upstream publishes no macOS binaries (and nixpkgs marks the
//!      darwin build broken), so Crosschat's `prebuilt-vN` release carries
//!      ones built from the unmodified tag by `scripts/build-prebuilt.sh`.
//!
//! Users never compile anything. Building from source (`cargo install` at the
//! pinned tag, ~10 min) only happens for developers who opt in with
//! `CROSSCHAT_ALLOW_SOURCE_BUILDS=1` or `crosschatd install-tuwunel --from-source`.
//!
//! `$PATH` is deliberately not searched: a random `tuwunel` of another
//! version could silently migrate the database.

use anyhow::{Context, Result, anyhow, bail};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::AsyncBufReadExt;
use tracing::info;

/// Pinned Tuwunel release.
pub const VERSION: &str = "v1.9.3";
pub const REPO: &str = "matrix-construct/tuwunel";

/// Linux release assets for [`VERSION`] (generic x86_64-v1 / aarch64-v8
/// builds) with their SHA-256 from the GitHub release.
pub const LINUX_ASSETS: &[(&str, &str, &str)] = &[
    (
        "linux-amd64",
        "v1.9.3-release-all-x86_64-v1-linux-gnu-tuwunel.zst",
        "98c3b0be352cc03b2c6b21d6f2ed60fedc926f4aab61ce37f0b89eed97d5b756",
    ),
    (
        "linux-arm64",
        "v1.9.3-release-all-aarch64-v8-linux-gnu-tuwunel.zst",
        "c1a309fe9dc167a40cefddee999d279f752fb493bb00a52af41584c434ba838f",
    ),
];

/// Crosschat's release with prebuilt binaries upstream doesn't publish.
pub const PREBUILT_REPO: &str = "devonkinghorn/crosschat";
pub const PREBUILT_RELEASE: &str = "prebuilt-v1";

/// macOS builds of [`VERSION`] in [`PREBUILT_RELEASE`] (minimum macOS 12)
/// with their SHA-256 (also in `prebuilt/SHA256SUMS`).
pub const MACOS_ASSETS: &[(&str, &str, &str)] = &[
    (
        "darwin-arm64",
        "tuwunel-v1.9.3-darwin-arm64.zst",
        "3e44eb10ce750c5340434ffd9fd6aa0b5b045995383eb52aa2337fb43410b6af",
    ),
    (
        "darwin-amd64",
        "tuwunel-v1.9.3-darwin-amd64.zst",
        "493e969b0d5f807676b5055073e69c02643f5edd3ddb42c52564780918aead85",
    ),
];

/// Cargo features for the macOS source build: upstream defaults minus the
/// Linux-only ones (`io_uring`, `systemd`) and jemalloc.
pub const MACOS_FEATURES: &str = "brotli_compression,element_hacks,gzip_compression,media_thumbnail,release_max_log_level,url_preview,zstd_compression";

/// Progress callback (human-readable status lines).
pub type Progress = Arc<dyn Fn(String) + Send + Sync>;

/// Per-user cache directory: `CROSSCHAT_CACHE_DIR`, else
/// `~/Library/Caches/Crosschat` (macOS) or `$XDG_CACHE_HOME/crosschat`
/// (`~/.cache/crosschat`).
pub fn cache_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("CROSSCHAT_CACHE_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(d);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        return home.join("Library/Caches/Crosschat");
    }
    std::env::var_os("XDG_CACHE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".cache"))
        .join("crosschat")
}

/// Where the pinned version lives in the cache.
pub fn cached_path(cache: &Path) -> PathBuf {
    cache.join(format!("tuwunel-{VERSION}")).join("bin/tuwunel")
}

/// Candidate locations in resolution order (steps 1-4), without touching
/// the filesystem.
pub fn candidates(
    env_bin: Option<PathBuf>,
    configured: Option<&Path>,
    exe_dir: Option<&Path>,
    cache: &Path,
) -> Vec<PathBuf> {
    let mut out = Vec::new();
    out.extend(env_bin);
    out.extend(configured.map(Path::to_path_buf));
    out.extend(exe_dir.map(|d| d.join("tuwunel")));
    out.push(cached_path(cache));
    out
}

/// Resolve the Tuwunel binary, installing the pinned version if needed.
pub async fn resolve(
    configured: Option<&Path>,
    http: &reqwest::Client,
    progress: Progress,
) -> Result<PathBuf> {
    let env_bin = std::env::var_os("TUWUNEL_BIN")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    if let Some(p) = &env_bin
        && !p.is_file()
    {
        bail!("TUWUNEL_BIN={} does not exist", p.display());
    }
    if let Some(p) = configured
        && env_bin.is_none()
        && !p.is_file()
    {
        bail!(
            "homeserver.bundled.binary = {} does not exist (remove it to let crosschatd install Tuwunel {VERSION})",
            p.display()
        );
    }
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf));
    let cache = cache_dir();
    if let Some(found) = candidates(env_bin, configured, exe_dir.as_deref(), &cache)
        .into_iter()
        .find(|p| p.is_file())
    {
        return Ok(found);
    }
    match install(&cache, http, progress.clone(), false).await {
        Err(e) if cfg!(target_os = "macos") && crate::installer::source_builds_allowed() => {
            tracing::warn!(
                "prebuilt Tuwunel unavailable ({e:#}); building from source (developer opt-in)"
            );
            install(&cache, http, progress, true).await
        }
        other => other,
    }
}

/// Install the pinned Tuwunel into `cache` and return its path: download
/// the prebuilt binary, or build from source when `from_source` (developer
/// option) is set.
pub async fn install(
    cache: &Path,
    http: &reqwest::Client,
    progress: Progress,
    from_source: bool,
) -> Result<PathBuf> {
    let target = cached_path(cache);
    if from_source {
        if !cfg!(target_os = "macos") {
            bail!("source builds of Tuwunel are only wired up for macOS");
        }
        build_from_source(cache, &target, progress).await?;
        return Ok(target);
    }
    let platform = crate::manifest::current_platform();
    let (repo, release, file, sha) = asset(&platform).ok_or_else(|| {
        anyhow!("the Matrix server (Tuwunel {VERSION}) isn't available for this computer ({platform}); set TUWUNEL_BIN")
    })?;
    download(&target, http, progress, repo, release, file, sha).await?;
    Ok(target)
}

/// Release asset for a platform: `(repo, release tag, file, sha256)`.
pub fn asset(platform: &str) -> Option<(&'static str, &'static str, &'static str, &'static str)> {
    let find = |list: &'static [(&str, &str, &str)]| {
        list.iter()
            .find(|(p, _, _)| *p == platform)
            .map(|(_, f, h)| (*f, *h))
    };
    if let Some((f, h)) = find(LINUX_ASSETS) {
        return Some((REPO, VERSION, f, h));
    }
    find(MACOS_ASSETS).map(|(f, h)| (PREBUILT_REPO, PREBUILT_RELEASE, f, h))
}

/// Decompress a (possibly multi-frame) zstd stream.
pub fn unzstd(bytes: &[u8]) -> Result<Vec<u8>> {
    use std::io::Read;
    let mut cursor = std::io::Cursor::new(bytes);
    let mut out = Vec::new();
    while (cursor.position() as usize) < bytes.len() {
        let mut dec = ruzstd::decoding::StreamingDecoder::new(&mut cursor)
            .map_err(|e| anyhow!("zstd: {e}"))?;
        dec.read_to_end(&mut out).context("zstd decode")?;
    }
    Ok(out)
}

async fn download(
    target: &Path,
    http: &reqwest::Client,
    progress: Progress,
    repo: &str,
    release: &str,
    file: &str,
    sha: &str,
) -> Result<()> {
    let url = crate::installer::release_url(repo, release, file);
    progress(format!("Downloading the Matrix server (Tuwunel {VERSION})"));
    info!(%url, "downloading tuwunel");
    let bytes = http
        .get(&url)
        .send()
        .await?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .bytes()
        .await?;
    let actual = crate::installer::sha256_hex(&bytes);
    if actual != sha {
        bail!("checksum mismatch for {file}: expected {sha}, got {actual}");
    }
    let bin = tokio::task::spawn_blocking(move || unzstd(&bytes)).await??;
    write_executable(target, &bin)
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
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Find `cargo`: `$CARGO`, rustup's `~/.cargo/bin`, Homebrew, then `$PATH`.
/// Apps launched from Finder get a minimal `$PATH`, hence the explicit list.
pub fn find_cargo() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut c: Vec<PathBuf> = Vec::new();
    c.extend(std::env::var_os("CARGO").map(PathBuf::from));
    c.extend(home.map(|h| h.join(".cargo/bin/cargo")));
    c.push("/opt/homebrew/bin/cargo".into());
    c.push("/usr/local/bin/cargo".into());
    if let Some(path) = std::env::var_os("PATH") {
        c.extend(std::env::split_paths(&path).map(|d| d.join("cargo")));
    }
    c.into_iter().find(|p| p.is_file())
}

/// `$PATH` for the macOS source build: Apple's toolchain first, so a
/// Nix/Homebrew `gcc`/`cc` can't shadow Apple clang (RocksDB and other C++
/// deps fail with GCC on macOS).
pub fn macos_build_path(cargo: &Path, current: Option<&std::ffi::OsStr>) -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .iter()
        .map(PathBuf::from)
        .collect();
    if let Some(d) = cargo.parent() {
        dirs.push(d.to_path_buf());
    }
    if let Some(cur) = current {
        dirs.extend(std::env::split_paths(cur));
    }
    std::env::join_paths(dirs).unwrap_or_default()
}

async fn build_from_source(cache: &Path, target: &Path, progress: Progress) -> Result<()> {
    let cargo = find_cargo().ok_or_else(|| {
        anyhow!(
            "building Tuwunel on macOS needs Rust: install it from https://rustup.rs (or set TUWUNEL_BIN)"
        )
    })?;
    let root = target
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| anyhow!("bad install path"))?
        .to_path_buf();
    std::fs::create_dir_all(cache)?;
    let log_path = cache.join("tuwunel-build.log");
    let log = std::fs::File::create(&log_path)?;
    progress(format!(
        "Building the Matrix server (Tuwunel {VERSION}) from source. first run on macOS only, ~10 min"
    ));
    info!(cargo = %cargo.display(), log = %log_path.display(), "building tuwunel from source");
    let mut cmd = tokio::process::Command::new(&cargo);
    cmd.args([
        "install",
        "--git",
        &format!("https://github.com/{REPO}"),
        "--tag",
        VERSION,
        "--locked",
        "--root",
    ])
    .arg(&root)
    .args([
        "--no-default-features",
        "--features",
        MACOS_FEATURES,
        "tuwunel",
    ])
    // Keep the target dir so an interrupted build resumes.
    .env("CARGO_TARGET_DIR", cache.join("tuwunel-build-target"))
    .env(
        "PATH",
        macos_build_path(&cargo, std::env::var_os("PATH").as_deref()),
    )
    // A CC/CXX/AR from Nix breaks the C++ deps; Apple clang is the default.
    .env_remove("CC")
    .env_remove("CXX")
    .env_remove("AR")
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::piped())
    .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .with_context(|| format!("running {}", cargo.display()))?;
    let stderr = child.stderr.take().expect("piped stderr");
    let mut lines = tokio::io::BufReader::new(stderr).lines();
    let mut compiled = 0usize;
    let mut log = std::io::BufWriter::new(log);
    let mut tail: std::collections::VecDeque<String> = Default::default();
    while let Some(line) = lines.next_line().await? {
        use std::io::Write;
        let _ = writeln!(log, "{line}");
        if line.trim_start().starts_with("Compiling ") {
            compiled += 1;
            if compiled.is_multiple_of(10) {
                progress(format!(
                    "Building the Matrix server (Tuwunel {VERSION}) from source: {compiled} crates compiled. first run on macOS only, ~10 min"
                ));
            }
        }
        tail.push_back(line);
        if tail.len() > 15 {
            tail.pop_front();
        }
    }
    {
        use std::io::Write;
        let _ = log.flush();
    }
    let status = child.wait().await?;
    if !status.success() || !target.is_file() {
        bail!(
            "building Tuwunel failed ({status}); full log: {}\n{}",
            log_path.display(),
            tail.into_iter().collect::<Vec<_>>().join("\n")
        );
    }
    // The build tree is several GB; the binary is all we need.
    let _ = std::fs::remove_dir_all(cache.join("tuwunel-build-target"));
    progress(format!("Built Tuwunel {VERSION}"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidate_order() {
        let cache = Path::new("/c");
        let c = candidates(
            Some("/env/tuwunel".into()),
            Some(Path::new("/cfg/tuwunel")),
            Some(Path::new("/app/bin")),
            cache,
        );
        assert_eq!(
            c,
            vec![
                PathBuf::from("/env/tuwunel"),
                PathBuf::from("/cfg/tuwunel"),
                PathBuf::from("/app/bin/tuwunel"),
                PathBuf::from(format!("/c/tuwunel-{VERSION}/bin/tuwunel")),
            ]
        );
        assert_eq!(candidates(None, None, None, cache).len(), 1);
    }

    #[test]
    fn assets_are_pinned_for_every_desktop_platform() {
        for p in ["linux-amd64", "linux-arm64"] {
            let (repo, tag, file, sha) = asset(p).unwrap();
            assert_eq!((repo, tag), (REPO, VERSION));
            assert!(file.starts_with(VERSION), "{file}");
            assert!(file.ends_with(".zst"));
            assert_eq!(sha.len(), 64);
        }
        for p in ["darwin-arm64", "darwin-amd64"] {
            let (repo, tag, file, sha) = asset(p).unwrap();
            assert_eq!((repo, tag), (PREBUILT_REPO, PREBUILT_RELEASE));
            assert_eq!(file, format!("tuwunel-{VERSION}-{p}.zst"));
            assert!(
                sha.len() == 64 && sha.bytes().all(|b| b.is_ascii_hexdigit()),
                "{sha}"
            );
        }
        assert!(asset("linux-armv7").is_none());
    }

    #[test]
    fn macos_assets_match_prebuilt_sums() {
        let sums = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../prebuilt/SHA256SUMS"),
        )
        .unwrap();
        for (_, file, sha) in MACOS_ASSETS {
            assert_eq!(
                crate::installer::parse_checksums(&sums, file).as_deref(),
                Some(*sha),
                "{file}"
            );
        }
    }

    #[test]
    fn macos_build_path_puts_apple_toolchain_first() {
        let p = macos_build_path(
            Path::new("/Users/d/.cargo/bin/cargo"),
            Some(std::ffi::OsStr::new("/nix/profile/bin:/opt/homebrew/bin")),
        );
        let dirs: Vec<PathBuf> = std::env::split_paths(&p).collect();
        assert_eq!(dirs[0], PathBuf::from("/usr/bin"));
        let nix = dirs.iter().position(|d| d.starts_with("/nix")).unwrap();
        let cargo = dirs
            .iter()
            .position(|d| d == Path::new("/Users/d/.cargo/bin"))
            .unwrap();
        assert!(cargo < nix);
    }

    #[test]
    fn zstd_roundtrip_of_known_frame() {
        // `printf hello | zstd -c` (single frame, raw block).
        let frame: [u8; 18] = [
            0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x29, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
            0xa3, 0x6d, 0x9f, 0x88,
        ];
        assert_eq!(unzstd(&frame).unwrap(), b"hello");
        let two = [frame, frame].concat();
        assert_eq!(unzstd(&two).unwrap(), b"hellohello");
    }

    #[test]
    fn cache_dir_override() {
        // SAFETY: tests touching this variable run in this test only.
        unsafe { std::env::set_var("CROSSCHAT_CACHE_DIR", "/tmp/cc-cache") };
        assert_eq!(cache_dir(), PathBuf::from("/tmp/cc-cache"));
        unsafe { std::env::remove_var("CROSSCHAT_CACHE_DIR") };
    }
}
