#!/usr/bin/env bash
# Build Crosschat's prebuilt binaries: the assets of the `prebuilt-vN` GitHub
# release on devonkinghorn/crosschat. They exist so end users never need Go,
# Rust, Xcode or a compiler: crosschatd downloads them (SHA-256 pinned in
# manifests/*.yaml and crates/crosschatd/src/tuwunel.rs), and the macOS app
# bundles the default-on ones.
#
# Everything is built from unmodified upstream source at the pinned tags or
# commits below (AGPL/Apache: the release notes link the exact sources).
#
# Usage: scripts/build-prebuilt.sh [options] TARGET...
#   TARGET        darwin-arm64 | darwin-amd64 | linux-amd64 | linux-arm64
#   --out DIR     output directory (default: dist/prebuilt)
#   --bridges     only build bridges
#   --tuwunel     only build Tuwunel
#   --no-package  leave raw binaries (skip zstd + SHA256SUMS)
#   --package     only package: compress raw binaries in --out, write SHA256SUMS
#
# Host requirements (builders only, never users):
#   darwin-*  a Mac with Xcode command line tools, Go (GOTOOLCHAIN=auto
#             fetches the toolchain the bridges pin) and rustup with the
#             aarch64/x86_64-apple-darwin targets.
#   linux-*   Go and zig (static musl cgo cross-compile), any host OS.
#   package   zstd and sha256sum/shasum.
# Which bridge is built for which platform: upstream mautrix publishes static
# Linux binaries (used as-is), but its darwin binaries link Homebrew libolm,
# so gmessages/slack are built here for darwin with the pure-Go olm (goolm).
# GroupMe has no upstream releases, so it is built for every platform. Tuwunel
# publishes Linux binaries but none for macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Pins (keep in sync with manifests/*.yaml and tuwunel.rs; the crosschatd
# tests check the manifests against prebuilt/SHA256SUMS). ---
# Go build tags: goolm (pure-Go olm, no libolm) for bridgev2 bridges.
# mautrix-imessage (legacy, master's last commit, macOS-only `mac`
# connector) predates goolm, so it's built without Matrix encryption
# (nocrypto); it only talks to the homeserver on the same Mac.
BRIDGES=(
  # id        repo                                     rev                                        package                    targets                                            tags
  "gmessages  https://github.com/mautrix/gmessages.git v0.2609.0                                  ./cmd/mautrix-gmessages    darwin-arm64,darwin-amd64                          goolm"
  "slack      https://github.com/mautrix/slack.git     v0.2609.1                                  ./cmd/mautrix-slack        darwin-arm64,darwin-amd64                          goolm"
  "groupme    https://github.com/beeper/groupme.git    ff4fbcc6211d7e24fb0c240f6dc15e95555962db   ./cmd/mautrix-groupme      darwin-arm64,darwin-amd64,linux-amd64,linux-arm64  goolm"
  "imessage   https://github.com/mautrix/imessage.git  300ba6d0e5566d1f841d42ee1555779a9b6fa4be   .                          darwin-arm64,darwin-amd64                          nocrypto"
)
TUWUNEL_VERSION=v1.9.3
TUWUNEL_REPO=https://github.com/matrix-construct/tuwunel
# Same as tuwunel.rs MACOS_FEATURES: upstream defaults minus the Linux-only
# io_uring/systemd and jemalloc.
TUWUNEL_FEATURES=brotli_compression,element_hacks,gzip_compression,media_thumbnail,release_max_log_level,url_preview,zstd_compression
# Minimum macOS: Go 1.27 (which the bridges pin) targets macOS 13; Tuwunel
# runs on 12.
BRIDGES_MACOS_MIN="${BRIDGES_MACOS_MIN:-13.0}"
TUWUNEL_MACOS_MIN="${TUWUNEL_MACOS_MIN:-12.0}"

OUT="$ROOT/dist/prebuilt"; DO_BRIDGES=1; DO_TUWUNEL=1; PACKAGE=1; ONLY_PACKAGE=0
TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --bridges) DO_TUWUNEL=0; shift ;;
    --tuwunel) DO_BRIDGES=0; shift ;;
    --no-package) PACKAGE=0; shift ;;
    --package) ONLY_PACKAGE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    darwin-arm64|darwin-amd64|linux-amd64|linux-arm64) TARGETS+=("$1"); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/.work"

HOST="$(uname -s)"
if [[ $HOST == Darwin ]]; then
  # Apple clang only: a Nix/Homebrew gcc first on PATH, or CC/CXX/AR from Nix,
  # breaks cgo and RocksDB ("conflicting deployment targets").
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
  unset CC CXX AR
fi

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

package() {
  command -v zstd >/dev/null || { echo "zstd is required to package" >&2; exit 1; }
  shopt -s nullglob
  for f in "$OUT"/mautrix-* "$OUT"/tuwunel-*; do
    if [[ $f == *.zst ]]; then continue; fi
    zstd -19 -T0 -q -f --rm "$f" -o "$f.zst"
  done
  (cd "$OUT" && sha256 ./*.zst | sed 's| \./| |' | sort -k2 > SHA256SUMS)
  echo "== $OUT/SHA256SUMS"; cat "$OUT/SHA256SUMS"
}

if [[ $ONLY_PACKAGE == 1 ]]; then package; exit 0; fi
[[ ${#TARGETS[@]} -gt 0 ]] || { echo "no TARGET given (see --help)" >&2; exit 2; }

build_bridge() { # id repo rev package target tags
  local id=$1 repo=$2 rev=$3 pkg=$4 target=$5 tags=${6:-goolm}
  local goos=${target%-*} goarch=${target#*-}
  command -v go >/dev/null || { echo "go is required to build bridges" >&2; exit 1; }
  local src="$WORK/src/$id"
  [[ -d $src/.git ]] || git clone -q --filter=blob:none "$repo" "$src"
  git -C "$src" fetch -q --tags origin
  git -C "$src" checkout -q --detach "$rev"
  local commit tag btime label mautrix
  commit=$(git -C "$src" rev-parse HEAD)
  tag=$(git -C "$src" describe --exact-match --tags 2>/dev/null || true)
  btime=$(git -C "$src" show -s --format=%cI HEAD)   # commit time: reproducible
  if [[ $rev == v* ]]; then label=$rev; else label=${rev:0:12}; fi
  local out="$OUT/mautrix-$id-$label-$target"
  local ldflags="-s -w -buildid= -X main.Tag=$tag -X main.Commit=$commit -X main.BuildTime=$btime"
  mautrix=$(cd "$src" && GOTOOLCHAIN=auto go list -m -f '{{.Version}}' maunium.net/go/mautrix 2>/dev/null || true)
  if [[ -n $mautrix ]]; then ldflags+=" -X maunium.net/go/mautrix.GoModVersion=$mautrix"; fi
  local -a env=(GOTOOLCHAIN=auto CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" GOFLAGS=)
  case "$goos" in
    darwin)
      [[ $HOST == Darwin ]] || { echo "$target needs a macOS host" >&2; exit 1; }
      # cmd/go passes -arch to Apple clang, so arm64 <-> amd64 needs no CC.
      env+=(MACOSX_DEPLOYMENT_TARGET="$BRIDGES_MACOS_MIN")
      ;;
    linux)
      local zig="${ZIG:-zig}" zarch
      command -v "$zig" >/dev/null || { echo "zig is required for $target" >&2; exit 1; }
      case $goarch in amd64) zarch=x86_64 ;; arm64) zarch=aarch64 ;; esac
      env+=(CC="$zig cc -target $zarch-linux-musl" CXX="$zig c++ -target $zarch-linux-musl")
      ldflags+=" -linkmode external -extldflags -static"
      ;;
  esac
  echo "== $id $label $target"
  (cd "$src" && env "${env[@]}" go build -trimpath -buildvcs=false -tags "$tags" \
      -ldflags "$ldflags" -o "$out" "$pkg")
}

build_tuwunel() { # target
  local target=$1 triple
  [[ $target == darwin-* ]] || { echo "Tuwunel: upstream ships Linux binaries; skipping $target"; return; }
  [[ $HOST == Darwin ]] || { echo "$target needs a macOS host" >&2; exit 1; }
  case $target in darwin-arm64) triple=aarch64-apple-darwin ;; darwin-amd64) triple=x86_64-apple-darwin ;; esac
  if command -v rustup >/dev/null; then rustup target add "$triple" >/dev/null; fi
  echo "== tuwunel $TUWUNEL_VERSION $target (~10 min)"
  MACOSX_DEPLOYMENT_TARGET="$TUWUNEL_MACOS_MIN" CARGO_TARGET_DIR="$WORK/tuwunel-target" cargo install -q --git "$TUWUNEL_REPO" --tag "$TUWUNEL_VERSION" \
    --locked --no-default-features --features "$TUWUNEL_FEATURES" \
    --target "$triple" --root "$WORK/tuwunel-$target" --force tuwunel
  cp "$WORK/tuwunel-$target/bin/tuwunel" "$OUT/tuwunel-$TUWUNEL_VERSION-$target"
}

for t in "${TARGETS[@]}"; do
  if [[ $DO_BRIDGES == 1 ]]; then
    for line in "${BRIDGES[@]}"; do
      read -r id repo rev pkg targets tags <<<"$line"
      if [[ ",$targets," == *",$t,"* ]]; then build_bridge "$id" "$repo" "$rev" "$pkg" "$t" "$tags"; fi
    done
  fi
  if [[ $DO_TUWUNEL == 1 ]]; then build_tuwunel "$t"; fi
done
if [[ $PACKAGE == 1 ]]; then package; fi
echo "done: $OUT"
