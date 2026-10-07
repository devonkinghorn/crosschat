#!/usr/bin/env bash
# Put crosschatd (and optionally Tuwunel) inside a built Crosschat app so
# "Start a new server on this computer" works without a source checkout.
#
# Usage: scripts/bundle-local-server.sh [--with-tuwunel] [APP]
#   APP defaults to the release build:
#     macOS: app/build/macos/Build/Products/Release/crosschat.app (-> Contents/MacOS/)
#     Linux: app/build/linux/x64/release/bundle
#   --with-tuwunel  also copy the pinned Tuwunel (downloaded on Linux, built
#                   from source on macOS the first time, ~7-20 min). Without
#                   it, crosschatd installs Tuwunel into the cache on first run.
#
# A dev build run from the checkout (flutter run) doesn't need this: the app
# finds target/release/crosschatd (or target/debug) by walking up from itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WITH_TUWUNEL=0
if [[ "${1:-}" == "--with-tuwunel" ]]; then WITH_TUWUNEL=1; shift; fi

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
cp "$ROOT/target/release/crosschatd" "$DEST/crosschatd"
echo "copied crosschatd -> $DEST/"

if [[ $WITH_TUWUNEL == 1 ]]; then
  TUW="$("$ROOT/target/release/crosschatd" install-tuwunel)"
  cp "$TUW" "$DEST/tuwunel"
  echo "copied $TUW -> $DEST/"
fi

if [[ "$(uname -s)" == Darwin ]]; then
  # Re-seal the bundle (ad-hoc) after adding executables.
  codesign --force --deep --sign - "$APP"
  echo "re-signed $APP (ad-hoc)"
fi
