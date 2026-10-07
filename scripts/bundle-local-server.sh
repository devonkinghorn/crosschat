#!/usr/bin/env bash
# Make a built Crosschat app self-contained for "Start a new server on this
# computer": copies crosschatd, the pinned Tuwunel and the default-on bridges
# (Google Messages, Slack) into it, so first run needs no compiler, no
# toolchain and no downloads. Optional bridges are still downloaded (prebuilt,
# SHA-256 pinned) when enabled.
#
# Usage: scripts/bundle-local-server.sh [--no-tuwunel] [--no-bridges] [APP]
#   APP defaults to the release build:
#     macOS: app/build/macos/Build/Products/Release/crosschat.app (-> Contents/MacOS/)
#     Linux: app/build/linux/x64/release/bundle
# Layout inside the app: crosschatd, tuwunel, bridges/<id>/<version>/<binary>.
# The binaries come from upstream releases or Crosschat's prebuilt-vN release
# (scripts/build-prebuilt.sh); this script itself only builds crosschatd.
#
# A dev build run from the checkout (flutter run) doesn't need this: the app
# finds target/release/crosschatd (or target/debug) by walking up from itself,
# and crosschatd downloads Tuwunel and the bridges into the cache/data dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WITH_TUWUNEL=1; WITH_BRIDGES=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-tuwunel) shift ;;   # the default now; kept for old instructions
    --no-tuwunel) WITH_TUWUNEL=0; shift ;;
    --no-bridges) WITH_BRIDGES=0; shift ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$(uname -s)" in
  Darwin)
    # Apple clang first; a Nix/Homebrew gcc on PATH breaks C/C++ deps.
    # Never set CC/CXX/AR for Xcode builds.
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
    unset CC CXX AR
    APP="${1:-$ROOT/app/build/macos/Build/Products/Release/crosschat.app}"
    DEST="$APP/Contents/MacOS"
    ;;
  Linux)
    APP="${1:-$ROOT/app/build/linux/x64/release/bundle}"
    DEST="$APP"
    ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac
[[ -d "$DEST" ]] || { echo "no app at $APP (build it first)" >&2; exit 1; }

cargo build --release -p crosschatd --manifest-path "$ROOT/Cargo.toml"
CROSSCHATD="$ROOT/target/release/crosschatd"
cp "$CROSSCHATD" "$DEST/crosschatd"
echo "copied crosschatd -> $DEST/"

if [[ $WITH_TUWUNEL == 1 ]]; then
  # Prebuilt and SHA-256 checked (upstream on Linux, prebuilt-vN on macOS).
  TUW="$(env -u TUWUNEL_BIN "$CROSSCHATD" install-tuwunel)"
  cp "$TUW" "$DEST/tuwunel"
  echo "copied $TUW -> $DEST/"
fi

if [[ $WITH_BRIDGES == 1 ]]; then
  rm -rf "$DEST/bridges"
  "$CROSSCHATD" fetch-bridges --dest "$DEST/bridges"
fi

if [[ "$(uname -s)" == Darwin ]]; then
  # Re-seal the bundle (ad-hoc) after adding executables, innermost first.
  if [[ -d "$DEST/bridges" ]]; then
    find "$DEST/bridges" -type f -perm -u+x -exec codesign --force --sign - {} \;
  fi
  for f in crosschatd tuwunel; do
    if [[ -f "$DEST/$f" ]]; then codesign --force --sign - "$DEST/$f"; fi
  done
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP"
  echo "re-signed $APP (ad-hoc)"
fi
du -sh "$APP"
