# Crosschat

**Open-source, self-hostable, native Beeper alternative built on Matrix.**

Crosschat is a Slack/Discord-style chat app that puts iMessage, RCS/SMS (Google Messages), Slack and GroupMe in one inbox. You run it on your own server:

- A **Rust core** ([matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk)).
- A **Flutter UI** via flutter_rust_bridge, with no Electron.
- A small daemon, **`crosschatd`**, that downloads, configures and supervises the unmodified upstream bridges.

> ⚠️ **Alpha.** Good for developers and tinkerers. Expect breaking changes. Nothing here has been tested with real iMessage, Google, Slack or GroupMe accounts yet.

![Crosschat demo mode: Slack thread open in the side panel](docs/screenshot.png)

## What works in the alpha

| Area | Status |
|---|---|
| **Rust core** (`crates/crosschat-core`) | Password login, session restore, a classic `/sync` loop with live updates, room list with network detection (`m.bridge`) and thread capability (`com.beeper.room_features`), timeline with **Matrix threads** folded into root summaries, thread panel via `/relations`, markdown sending, thread replies, user directory, DMs and groups. |
| **Daemon** (`crates/crosschatd`) | Manifest-driven bridge install: GitHub release with SHA-256 verification, or a Go build at a pinned commit. Config generation (bridge `-e` output + template + managed secrets), appservice registrations, token vault, process supervision with backoff and restarts, health polling, bridge status endpoint, **bundled Tuwunel** (federation must be chosen explicitly). |
| **Provisioning proxy** | `/_crosschat/v1/...`, authenticated with your Matrix token: the bridgev2 provisioning API for in-app logins, plus a **cross-network contact search** fan-out (`search_users` + `resolve_identifier`). |
| **Bridges** | Manifests for **iMessage** ([corten-matrix](https://github.com/lrhodin/corten-matrix)), **Google Messages** ([mautrix-gmessages](https://github.com/mautrix/gmessages)), **Slack** ([mautrix-slack](https://github.com/mautrix/slack)) and **GroupMe** ([beeper/groupme](https://github.com/beeper/groupme), early). All four ran live under `crosschatd` on Linux and returned their real login flows through the proxy. |
| **App** (`app/`) | Network rail, chat sidebar, dense message list, composer, **Slack-style thread side panel** (pushed routes on phones), and a new-chat dialog that searches bridges through crosschatd and falls back to Matrix users. **Generic bridgev2 login renderer**: forms, QR, code, emoji, cookies via paste, complete. Settings with the bridge list and the **Android "keep connection open"** foreground-service toggle. Capability flags such as macOS-only iMessage key extraction. Demo mode. |
| **Tests** | 47 daemon tests (unit + HTTP proxy against a fake bridge), 9 core unit tests, 10 Flutter widget tests, and an **end-to-end smoke test** against a real local Tuwunel with a real bridge (`scripts/smoke.sh`). |

## What doesn't work yet

- **No real-account logins have been tried.** Cookie logins (Google, Slack) use copy-paste on desktop: open the sign-in page, then paste a cURL command, Cookie header or JSON. There is no embedded webview capture yet.
- The **iMessage hardware-key extractor** button calls the upstream CLI on macOS, but it is untested: there's no Mac in CI.
- No E2EE verification or recovery UI. No media, reactions, read receipts, typing or rich-text rendering (messages show their plain `body`).
- Classic `/sync` only, no sliding sync yet. No encrypted store or keychain: `session.json` is saved with mode 0600.
- Android persistent sync keeps the process alive, but the sync loop lives in the activity's engine, so swiping the app away stops it.
- No push notifications. Push is planned for a paid tier.
- No setup wizard, Docker image or reverse-proxy recipes yet. **macOS, iOS and Windows builds are untested** (CI has a macOS job, but it isn't active yet; see below).
- WhatsApp, Signal and Telegram are not included yet. They'll be new manifests later. There is no BlueBubbles support.

## Layout

```
crates/crosschat-core   Rust client core (matrix-sdk 0.19)
crates/crosschatd       host daemon: manifests, installer, vault, supervisor, proxy, bundled HS
app/                    Flutter app; app/rust = flutter_rust_bridge crate (crosschat_ffi)
manifests/              bridge manifests (crosschat.bridge/v1)
deploy/                 example crosschatd.toml
scripts/smoke.sh        end-to-end test against a local Tuwunel
docs/ARCHITECTURE.md    design, decisions, risks
```

## Running it

Requirements:
- **Rust** ≥ 1.96 (`rustup`).
- **Flutter** 3.47+.
- **For Linux desktop builds:** `clang cmake ninja-build pkg-config libgtk-3-dev`.
- **For bridges:** Go, only if you enable GroupMe, which is built from source.

### 1. The daemon (on your server)

```bash
cargo build --release -p crosschatd
cp deploy/crosschatd.example.toml crosschatd.toml   # set server_name, admins, enabled bridges
./target/release/crosschatd validate manifests
./target/release/crosschatd run -c crosschatd.toml
```

- **Existing homeserver:** registrations are written to `data/registrations/`. Add them to your homeserver (e.g. Synapse `app_service_config_files`) and restart it. Tuwunel can load them from a directory: `registration = { kind = "directory", path = ... }`.
- **Bundled Tuwunel:** fill in `[homeserver.bundled]`. You must set `federation = true|false` explicitly. `server_name` can't be changed later.
- **Reverse proxy:** expose crosschatd on your homeserver's domain at `/_crosschat/`. The bridges stay on loopback.

Bridges are **downloaded from upstream at install time** and are never vendored. They are AGPL-3.0, except corten-matrix, which is MPL-2.0.

### 2. The app

```bash
cd app
flutter pub get
flutter run -d linux                                      # real Rust core: log in to any Matrix homeserver
flutter run -d linux --dart-define=CROSSCHAT_DEMO=true    # demo data, no server needed
flutter build linux                                       # or: flutter build apk
CROSSCHAT_DEMO=1 build/linux/x64/release/bundle/crosschat # demo mode for an already-built binary
```

By default the app looks for crosschatd at your homeserver URL. You can change it under Settings → Networks, e.g. `http://127.0.0.1:29300`. Without crosschatd the app still works as a plain Matrix client.

### Android

The APK embeds the **real Rust core**: cargokit cross-compiles `crosschat_ffi` for each Android ABI with the NDK. Demo mode is only used with `--dart-define=CROSSCHAT_DEMO=true`, or if the native library fails to load.

```bash
# Prerequisites
# - Android SDK with platforms;android-36, build-tools;36.0.0, ndk;28.2.13676358
#   (Gradle fetches CMake itself)
# - JDK 17+
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cd app
flutter build apk --release --split-per-abi --target-platform android-arm64   # ~70 MB, most phones
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Notes:
- **Set `JAVA_HOME`** to your JDK directory, not `/usr`. Flutter puts `$JAVA_HOME/bin` first on Gradle's `PATH`. If that's `/usr/bin` and your distro ships an old `/usr/bin/rustc`, the NDK build picks up the wrong compiler.
- **Signing.** Release builds are signed with the debug key, so they're fine for sideloading but not for the Play Store.
- **Persistent sync.** Enable it under Settings → Background sync. It shows an ongoing notification. On Android 13+ the app asks for notification permission.

### macOS (step by step)

> ⚠️ Not tested on a Mac yet. These steps match what the CI macOS job runs.

1. **Xcode.** Install it from the App Store, then run:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   ```
2. **Homebrew tools.** Flutter, CocoaPods (some Flutter plugins still use it), and Go (only needed for the GroupMe bridge):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install --cask flutter
   brew install cocoapods go
   flutter doctor            # Xcode and macOS should be ✓
   ```
3. **Rust** (≥ 1.96), with both Mac targets so universal release builds work:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
   source "$HOME/.cargo/env"
   rustup update stable
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```
4. **Clone and test:**
   ```bash
   git clone https://github.com/devonkinghorn/crosschat.git
   cd crosschat
   cargo build && cargo test
   ```
5. **Run crosschatd** on the Mac. This is optional: the daemon can also run on a Linux server.
   ```bash
   cargo build --release -p crosschatd
   cp deploy/crosschatd.example.toml crosschatd.toml
   # edit: [homeserver] url + server_name, [auth] admins = ["@you:your.server"], enable bridges
   ./target/release/crosschatd validate manifests
   ./target/release/crosschatd run -c crosschatd.toml
   ```
   Tuwunel publishes Linux binaries only, so on a Mac point crosschatd at an existing homeserver (or build Tuwunel from source, untested). The mautrix bridges ship `darwin-arm64` binaries. corten-matrix (iMessage) is used as published upstream.
6. **Run the app:**
   ```bash
   cd app
   flutter pub get
   flutter run -d macos                                    # real Rust core
   flutter run -d macos --dart-define=CROSSCHAT_DEMO=true  # demo data
   flutter build macos --release
   open build/macos/Build/Products/Release/crosschat.app
   ```
   Set the crosschatd URL under Settings → Networks if it isn't served at your homeserver's `/_crosschat/` (e.g. `http://127.0.0.1:29300`).
7. **CI build instead.** The unsigned CI artifact (`crosschat-macos-unsigned.zip`) isn't notarized. After unzipping, run `xattr -dr com.apple.quarantine crosschat.app` before opening it.
8. **iMessage on a Linux host.** Download the upstream corten-matrix `extract-key` tool. Set its path in Settings (the macOS-only "iMessage hardware key" section). Then use **Extract from this Mac** in the iMessage login dialog. Turn **Contact Key Verification off** first.

The alpha macOS app is **unsandboxed** so it can run the extractor. It has the `network.client` entitlement.

### 3. Tests

```bash
cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings
cargo build && cargo test                       # unit + proxy tests (core smoke test skips without a server)
(cd app && flutter analyze && flutter test)

# End-to-end. Starts a bundled Tuwunel via crosschatd, installs mautrix-gmessages,
# registers a user, runs the Rust core smoke test (login/send/threads/sync/restore),
# then checks bridge health and the provisioning proxy.
TUWUNEL_BIN=/path/to/tuwunel scripts/smoke.sh
SMOKE_BRIDGES="gmessages slack imessage groupme" TUWUNEL_BIN=... scripts/smoke.sh   # all four (groupme needs Go)
```

CI covers Rust fmt/clippy/test, the end-to-end smoke test, Flutter analyze/test, a Linux build, an APK build, and a macOS job (cargo test plus `flutter build macos`, uploading the unsigned .app). The workflow lives in [`ci/github-actions-ci.yml`](ci/github-actions-ci.yml) and isn't active yet: the token that pushed this alpha lacked GitHub's `workflow` scope. To enable it, run `git mv ci/github-actions-ci.yml .github/workflows/ci.yml` and push with a token that has that scope.

## Network notes

- **iMessage** (corten-matrix): on a Linux host it needs an Apple hardware key, extracted **once on a Mac**. The macOS app can run the upstream extractor. **Contact Key Verification must be off** on your Apple ID.
- **RCS/SMS** (Google Messages): Google-account cookie login. QR pairing no longer works. **Your Android phone must stay on and online.**
- **Slack:** an `xoxc-` token plus the `d` cookie (or email / Slack app).
- **GroupMe:** early. It's built from source at a pinned commit.

## Roadmap

1. **Daily-drivable:** E2EE verification and recovery, media, reactions, receipts, rich text, sliding sync, keychain storage.
2. **Logins without a terminal:** an embedded cookie webview, real-account testing of all four networks, a health screen.
3. **Setup wizard:** bundled homeserver, server-name and federation choice, owner bootstrap, a Docker image, reverse-proxy recipes.
4. **Mobile:** sync loop inside the Android service, iOS, then an optional paid push tier and a ~$1/mo TLS-passthrough relay. The relay is documented only.
5. **More networks:** WhatsApp, Signal, Telegram.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and the risks: bridge-host decryption, account bans, maintenance churn and onboarding.

## License

Crosschat is licensed under [Apache-2.0](LICENSE). Bridges are separate upstream projects under their own licenses and are downloaded at install time.
