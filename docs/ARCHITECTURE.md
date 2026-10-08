# Crosschat: architecture

*Formerly "Switchboard". Draft 3, Oct 7, 2026. Status markers: ✅ in the alpha, 🚧 partial, 📋 planned. ⚠️ marks unverified or uncertain items.*

Crosschat is an open-source, self-hostable, native alternative to Beeper. It's a Matrix client plus a host daemon that runs upstream bridges for you.

## 1. Goals and non-goals

**Goals**
- A unified inbox on Matrix with a **Slack/Discord-style UI**: a left rail of networks, a chat sidebar, a dense message list, and a Slack-style thread side panel.
- **Native, no Electron.** The core is Rust ([matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk)). The UI is Flutter, bound to Rust with [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge), on Linux, macOS, Windows, Android, and iOS.
- **Any Matrix homeserver**, or a **bundled Tuwunel/Continuwuity** that Crosschat sets up. With the bundled server, federation is an explicit choice made at setup.
- **Turnkey bridges.** Unmodified upstream bridges, supervised by `crosschatd`, with logins done inside the app.
- **Device-specific features are first-class.** Some things only one platform can do, such as extracting the iMessage hardware key on a Mac. The app exposes these through capability flags instead of lowest-common-denominator features.

**Non-goals for v1**
- Our own Matrix engine or our own bridges.
- Calls, a web client, or multi-tenant hosting.
- Running bridges or a homeserver on phones.
- BlueBubbles. iMessage goes through corten-matrix only.
- WhatsApp, Signal, and Telegram. They come after the first four networks. Their bridges are bridgev2 too, so each is just a new manifest.

## 2. System overview

```mermaid
flowchart LR
  subgraph Devices["User devices (clients only)"]
    D["Desktop app<br/>Flutter + crosschat-core (FRB)"]
    P["Android app<br/>Flutter + crosschat-core (FRB)<br/>opt-in persistent sync service"]
    M["macOS app<br/>+ iMessage hardware-key extractor"]
  end
  subgraph Host["Your server: Linux box / Mac mini / VPS"]
    RP["Reverse proxy<br/>/_matrix → homeserver<br/>/_crosschat → crosschatd"]
    CD["crosschatd<br/>supervisor, vault, provisioning proxy"]
    HS[("Homeserver<br/>any Matrix server, or<br/>bundled Tuwunel / Continuwuity")]
    subgraph Bridges["Bridges (separate, unmodified processes on loopback)"]
      IM["corten-matrix (iMessage)"]
      GM["mautrix-gmessages (RCS/SMS)"]
      SL["mautrix-slack"]
      GR["beeper/groupme"]
    end
  end
  D & P & M -- "Matrix C-S API" --> RP --> HS
  D & P & M -- "/_crosschat/v1 (Matrix token)" --> RP --> CD
  CD -- "spawn · health · restart" --> Bridges
  CD -- "provisioning proxy (shared secret)" --> Bridges
  CD -- "spawn + config (bundled mode)" --> HS
  HS <-- "appservice API" --> Bridges
```

**One Rust workspace, three crates**

| Crate | Role | Status |
|---|---|---|
| `crates/crosschat-core` | Client facade over matrix-sdk 0.19: login and restore, sync, rooms, timeline, threads, send, user directory, DMs and groups. The only Matrix API Dart sees. | ✅ |
| `crates/crosschatd` | Host daemon: bridge manifests, installer, appservice registrations, token vault, supervisor, health, provisioning proxy, bundled homeserver. | ✅ |
| `app/rust` (`crosschat_ffi`) | flutter_rust_bridge 2.13 API over `crosschat-core`, with its own Tokio runtime and a `StreamSink` for updates. | ✅ |

**Why the split?** The homeserver *pushes* events to bridges over HTTP, and registering a bridge needs homeserver admin rights. So bridges must live where the homeserver can reach them, which rules out laptops and phones. Every device is just a Matrix client with its own device keys.

**Deployment modes**
- **Existing homeserver.** `crosschatd` manages the bridges only. Registrations are written to `data/registrations/`. For Synapse you add them to `app_service_config_files` and restart. Tuwunel can load them from an `appservice_dir` (`registration = { kind = "directory" }`).
- **Bundled homeserver.** `crosschatd` writes a Tuwunel config and runs it as a supervised child process, started before the bridges. `federation` has **no default**: the config refuses to load until you choose `true` or `false`. ✅ (Tuwunel). Continuwuity 📋.
- **Local (this computer only).** ✅ The desktop app's default first-run choice. It starts `crosschatd local`, which runs a bundled Tuwunel with `server_name = "localhost"`, federation off and loopback-only listeners, plus the bridges. See §4.3.
- **Client only.** The app logs in to any Matrix account without `crosschatd`. Bridge UI and contact search degrade gracefully.

## 3. Client core (`crosschat-core`)
- **SDK.** matrix-sdk 0.19.1 with sqlite stores, E2EE, and markdown. MSRV is Rust 1.96.
- **Sync.** ✅ The alpha runs a classic `/sync` loop (`sync_once` with backoff) and broadcasts `CoreEvent`s: `RoomsChanged`, `NewMessage`, `SyncState`. Classic sync works with any homeserver. 📋 Next: move to matrix-sdk-ui `RoomListService`/`Timeline` on Simplified Sliding Sync when the server supports it, and keep classic sync as the fallback.
- **Rooms.** ✅ The network comes from `m.bridge` or `uk.half-shot.bridge` state, with a fallback on the ghost-user prefix. Thread support comes from `com.beeper.room_features` (a `thread` level above 0 means supported).
  - **One rail entry per bridge login, not per `protocol.id`.** Bridges may vary `protocol.id` per chat: mautrix-gmessages says `gmessages-rcs` or `gmessages-sms` (and `gmessages` on its space), mautrix-slack says `slackgo`. The core folds these to the bridge's network (`canonical_network_id`: the appservice id from the bridgev2 state key `<server>/<appservice id>`, a known `<network>-<sub>` prefix, or a `<network>go` Beeper type) and keeps the raw protocol, the bridge bot and the login (`channel.fi.mau.receiver`). The app (`state/network_groups.dart`) then matches chats to crosschatd's bridges by bot / appservice id, splits a network only when the user has several accounts on it (subtitle = the account), and shows RCS/SMS as a badge on the chat row. Spaces (the bridge's per-account space) are not chats and are skipped.
  - **Sync and health per entry.** The app polls bridgev2 `GET /v3/whoami` through crosschatd (every 3 s while something is syncing, 30 s otherwise). Right after a login completes, the network appears in the rail as "Syncing chats… N so far" (spinner) before its first chat exists, and settles once no new chats arrive for 20 s. `BACKFILLING`/`CONNECTING` show as syncing/connecting. `BAD_CREDENTIALS`/`LOGGED_OUT` show "sign in again" with a button. Other error states, or a bridge that doesn't answer, show as a warning. An entry with no chats and nothing going on is hidden.
- **Threads.** ✅ The main timeline folds `m.thread` replies into a summary on the root: reply count, latest reply, participants. The thread panel reads replies with the `/relations` API. Thread replies are sent as `m.thread` relations, with the reply fallback set to the latest event. Edits (`m.replace`) are applied.
- **Session.** ✅ `session.json` is stored with mode 0600, alongside the sqlite store. 📋 Move the token to the OS keychain and encrypt the store with a keychain-held passphrase.
- **Read state.** ✅ Opening a chat (a user click, not the startup auto-select) sends `/read_markers` with `m.fully_read` plus a public `m.read` receipt for the newest message, so the server resets the unread count and bridges (which get receipts through MSC2409 ephemeral events) forward the read status. While the chat is open and the window is focused, new messages are marked read (debounced 500 ms). Receipts are deduplicated against the last one sent and the stored own receipt, because Tuwunel re-emits equal or older receipts (issue #516) and that could loop with bridges. The app clears the badge at once and keeps it cleared until the server catches up or a newer message arrives. Mark as unread / Mark as read (right-click on desktop, long-press on mobile) write MSC2867 `m.marked_unread` and `com.famedly.marked_unread` room account data. Either one is honored, and the stable type wins when both exist.
- **Senders.** ✅ Names come from room member state (`display_name`, disambiguated as "Name (@id)" when ambiguous) and fall back to the profile API. Ghost users never show their MXID: the fallback is the phone number in the localpart, or "Unknown contact". Member, profile and ambiguity changes emit `TimelineChanged`, and the app reloads the open timeline. Avatars are loaded as thumbnails.
- **Media.** ✅ `m.image`/`m.video`/`m.audio`/`m.file`/`m.sticker` are parsed into a `MediaInfo` (plain `url` or encrypted `file`, mimetype, size, dimensions, filename vs. caption). The bytes come through `client.media().get_media_content`, which uses authenticated media (`/_matrix/client/v1/media`) when the server supports it, falls back to the legacy endpoints, and decrypts encrypted attachments. The app shows images inline (at most 360×320, animated GIFs, click for full size with download) and other files as a card with open/download. HEIC (iPhone photos, often labeled `image/jpeg`, detected by content) is converted to JPEG by the platform: ImageIO on macOS, ImageDecoder on Android. Elsewhere it falls back to the file card.
- **Reactions and tapbacks.** ✅ `m.reaction` annotations are grouped on their target (keys normalized without VS16). mautrix-gmessages sends SMS/iMessage tapbacks ("Laughed at an image", "Loved “…”", Google's "​👍​ to “…”") as plain text with no relation and no paired `m.reaction`. The core recognizes them (`content::parse_tapback`), and the app folds each one into a reaction on the quoted message, or on the latest image, video or message from someone else. If no target is loaded, it shows as a compact muted line.
- 📋 Verification, recovery, typing indicators.

## 4. Host daemon (`crosschatd`)

### 4.1 What it does
1. Loads `crosschatd.toml` and the bridge manifests (`manifests/*.yaml`, schema `crosschat.bridge/v1`, `deny_unknown_fields`).
2. **Vault** (`vault.json`, 0600). Holds per-bridge `as_token`/`hs_token`, provisioning secrets, pickle keys, the double-puppet token, the admin token, and the homeserver registration token. Nothing in the vault is ever sent to clients.
3. **Install.** **Users never compile anything.** A copy bundled with the app wins (`bridges/<id>/<version>/<binary>` next to crosschatd, or `$CROSSCHAT_BRIDGES_DIR`). Otherwise it downloads the pinned prebuilt release and verifies its SHA-256, against `sha256sums.txt` or a sha256 pinned in the manifest. Manifest validation rejects any artifact without a pin. Writes are atomic, and `.zst` assets are decompressed in-process. Where upstream has no usable binary (no releases at all, or darwin builds linking Homebrew's dropped `libolm`), the manifest points at Crosschat's `prebuilt-vN` release instead. Those assets are built from unmodified upstream source by `scripts/build-prebuilt.sh` (CI: manual `prebuilt-*` jobs), and `prebuilt/SHA256SUMS` is cross-checked against the manifests by a test. `go-build` sources still exist for developers, but run only with `CROSSCHAT_ALLOW_SOURCE_BUILDS=1`.
4. **Configure.** Runs the bridge's own `-e` to get its example config, deep-merges the manifest's `config:` template, then forces the managed keys: homeserver, appservice tokens, `127.0.0.1:<port>`, sqlite database, provisioning secret, double-puppet secret, permissions, and logging to stdout.
5. **Register.** Generates the registration with exclusive bot and ghost regexes and an escaped server name, plus a double-puppet appservice (`url: null`).
6. **Supervise.** Starts and stops processes (SIGTERM, then a kill after 10 s), with exponential backoff (1 s → 5 min, factor 2, reset after 2 min of uptime). A bridge is marked failed after 10 consecutive crashes. Logs go to a ring buffer and to `bridge.log`.
7. **Health.** Polls `/_matrix/mau/live` and `/ready`, and bridges POST per-login state to `/_crosschat/internal/bridge-status/{id}`.

### 4.2 API (`/_crosschat/v1`)
Clients authenticate with their **Matrix access token**. `crosschatd` validates it with `/account/whoami` and caches the result for 5 minutes, keyed by a hash of the token. Access is then checked against `auth.admins`, or all users on the server if `allow_server_users` is set.

| Route | Who | Purpose |
|---|---|---|
| `GET health` | public | liveness |
| `GET whoami` | user | who `crosschatd` thinks you are |
| `GET networks` | user | manifests with process state, health, capabilities, preflight checks, and requirements for this host OS |
| `POST search` | user | **contact search fan-out** across running bridges (bridgev2 `search_users`, plus `resolve_identifier` for phone numbers, emails, and handles), results merged and tagged by network |
| `GET contacts?bridge=` | user | bridgev2 `contacts` |
| `ANY bridges/{id}/provision/{v3/...}` | user | **provisioning proxy**: injects the shared secret and forces `user_id` to the caller, rejects path traversal and anything outside `v3/` |
| `POST bridges/{id}/{start,stop,restart}`, `GET bridges/{id}/logs` | admin | lifecycle |

**New chat.** The app searches through `POST /search`. Picking a result opens its existing DM room or calls `create_dm` through the proxy, then joins the portal. If `crosschatd` is unreachable, the dialog says so and falls back to the Matrix user directory. A hidden room with the bridge bot (`!gm pm +1555...`) is the last-resort fallback for bridges without the provisioning API 📋.

### 4.3 Local mode (`crosschatd local --dir <dir>`)
What the desktop app runs for **Start a new server on this computer**. Goal: Crosschat usable with no pre-existing homeserver.

- **Layout.** One directory (`~/Library/Application Support/Crosschat/server` on macOS, `$XDG_DATA_HOME/crosschat/server` on Linux): a generated, user-editable `crosschatd.toml` (`server_name = "localhost"`, `[homeserver.bundled] federation = false`, Tuwunel on `127.0.0.1:6167`, crosschatd on `127.0.0.1:29300`, Google Messages and Slack enabled), `local.json` (the owner), `crosschatd.log`, `crosschatd.pid`, and `data/`. Manifests are compiled into the binary and rewritten to `data/manifests` on each start. A config with federation on is refused.
- **Progress first.** Unlike `run`, the API binds *before* setup, so the app can poll `GET /_crosschat/v1/local/status` (`phase` = `starting`/`ready`/`failed`, a human-readable `detail`, `data_dir`, `owner`, URLs) while Tuwunel is installed and bridges are set up. Other routes answer 503 `CC_STARTING` until the daemon is ready, then everything is routed to the regular API. A second instance fails fast on the port.
- **Tuwunel binary** (`tuwunel.rs`, pinned v1.9.3): `$TUWUNEL_BIN` → `homeserver.bundled.binary` → `tuwunel` next to crosschatd (packaged app) → `<cache>/tuwunel-v1.9.3/bin/tuwunel`. Otherwise it downloads a `.zst` with a pinned SHA-256 into the cache and decompresses it in-process with `ruzstd`. On Linux that's the upstream release. On macOS, where upstream publishes no binaries and nixpkgs marks the darwin build broken, it's `prebuilt-v1`'s build of the same tag (arm64 + x86_64, macOS 12+): upstream default features minus the Linux-only `io_uring`/`systemd` and jemalloc, built with Apple clang (`/usr/bin` first on `PATH`, no `CC`/`CXX`/`AR`). The packaged app bundles it. A `cargo install` fallback exists for developers only (`CROSSCHAT_ALLOW_SOURCE_BUILDS=1` or `install-tuwunel --from-source`). `$PATH` is not searched on purpose: another version could migrate the database.
- **Owner bootstrap.** `POST /_crosschat/v1/local/owner {username, password}`, authorized with the local admin token from `data/admin.token` (readable only by the user; the app reads it). It works once (409 `CC_OWNER_EXISTS` afterwards). It registers the account on Tuwunel through user-interactive auth with the vault's `m.login.registration_token` (plus `m.login.dummy` if asked), saves `local.json`, and adds the owner to the admins at runtime. Tuwunel makes its first account a server admin. Registration stays token-gated, so nothing else can sign up.
- **App side** (`app/lib/src/local/`). `ProcessLocalServer` finds crosschatd (`$CROSSCHATD_BIN` → next to the app executable → `target/{release,debug}` of the checkout the app was built from → `$PATH`), starts it **detached** so bridges outlive the window, reuses an already-running one if its `data_dir` matches (and refuses a foreign one), creates the owner and logs in with the Rust core. Later launches start or reuse it before restoring the session. Desktop only; phones see the option disabled with an explanation.
- **Limits.** `localhost` can't federate and phones can't reach it. `server_name` is immutable, so moving to a real domain is a migration: re-backfill bridged chats from the networks and re-import native rooms through an appservice with timestamp massaging ([#1](https://github.com/devonkinghorn/crosschat/issues/1)).

### 4.4 Manifests
One YAML file per bridge. The sections are:
- `source`: `github-release` (artifacts per platform, each with a checksums file or a pinned sha256; `darwin-universal` covers both Mac arches) or `go-build` (repo, commit, tags; developer opt-in only).
- `source_overrides`: per-platform replacement sources. Google Messages and Slack use them on macOS: upstream's darwin binaries need Homebrew's `libolm`, which Homebrew dropped, so they point at `prebuilt-v1` builds of the same tag with `-tags goolm`, which link only system libraries.
- `process`: args and port.
- `registration`: bot and ghost localparts.
- `config`: deep-merge template.
- `login.flows`: hints for the UI.
- `capabilities`: `yes`/`no`/`unknown` per feature.
- `preflight`: blocking, warning, or info messages shown before login.
- `requirements`: things only some *client* platforms can provide. Each has `when_host`, `provided_by`, and `login_field`.
- `health`, `maturity`, `host_platforms`.

`crosschatd validate` checks every manifest. A unit test keeps the shipped manifests valid.

## 5. First networks

| Network | Bridge (upstream, downloaded at install) | Pin | Login | Notes |
|---|---|---|---|---|
| **iMessage** | [corten-matrix](https://github.com/lrhodin/corten-matrix) (MPL-2.0) | 1.3.2 (no checksums published; sha256 of each asset pinned in the manifest) | `apple-id`; on Linux `external-key` (`hardware_key` field) | On a Linux host it needs an Apple **hardware key extracted once on a Mac**. The macOS app runs the upstream CLI extractor and pastes the result (capability `canExtractAppleHardwareKey`). **Preflight (blocking): Contact Key Verification must be OFF.** |
| **RCS/SMS** | [mautrix-gmessages](https://github.com/mautrix/gmessages) | v0.2609.0 | `google` (cookies) | **QR pairing is dead**: v0.2609.0 offers only the Google-account cookie flow (verified via the proxy). After cookies, you confirm an emoji on the phone. **The phone must stay powered on and online.** |
| **Slack** | [mautrix-slack](https://github.com/mautrix/slack) | v0.2609.1 | `token`: `xoxc-` token plus the **`d` cookie** (also `email`, `app`) | Slack threads map to `m.thread`. The Slack-style panel is the native experience. |
| **GroupMe** | [beeper/groupme](https://github.com/beeper/groupme) | `ff4fbcc`, prebuilt by Crosschat (`prebuilt-v1`, `-tags goolm`, static musl on Linux) | `web`, `access-token` | **Early/alpha.** Upstream has no releases. |

All four ran live under `crosschatd` on Linux in the alpha's smoke test, and each returned its real login flows through the proxy. No real account logins were tested.

**Thread degradation.** For rooms whose `com.beeper.room_features` doesn't declare threads (iMessage, RCS, GroupMe), "Reply in thread" and the thread panel are hidden. We never fake threads that wouldn't reach the other side.

## 6. App (Flutter)
- **Layout** ✅: rail (72 px) | sidebar (260 px) | channel | thread panel (380 px). On narrow screens (phones), the channel and the thread push as full-screen routes.
- **Screens** ✅: first-run setup (new local server, the default, or an existing server), login, room list with network filter and unread badges, timeline (dense, grouped, day dividers, thread summary rows), composer (Enter to send), thread panel and composer, new-chat dialog, settings, generic bridge login dialog.
- **Generic bridgev2 login renderer** ✅ covers every bridgev2 bridge with one component:
  - `user_input`: text, phone, password, token, select. `hardware_key` gets an "Extract from this Mac" button on macOS.
  - `display_and_wait`: QR (`qr_flutter`), pairing code, emoji, then a long-poll for the next step.
  - `cookies`: current bridgev2 `fields[].sources[]` shape (and the legacy `type`/`name` shape). ✅ **Embedded sign-in window** (`lib/src/webauth/`, modeled on [mautrix-manager](https://github.com/mautrix/manager)'s `webview.ts`): the dialog opens a native window on `cookies.url` with a fresh, non-persistent cookie store per login (discarded on close) and keeps the user on the sign-in site (link clicks to other sites and app hand-offs like `slack://` are blocked; redirects and SSO form posts are allowed; pop-ups load in place). Dart polls the native cookie store (HttpOnly cookies included) and collects every source type: `cookie` (+`cookie_domain`, URL-decoded), `local_storage`, `request_header`/`request_body` (fetch/XHR hook injected at document start, matched by `request_url_regex`) and `special` (filled by the step's `extract_js`, run after each load). Values must match the field `pattern`. When every required field is in (and `wait_for_url_pattern` matches, if given) the window closes and the values are submitted, so Google Messages goes straight to the emoji step. Closing the window early offers to reopen it; if all required values were already captured it submits anyway, as bridgev2 allows. `user_agent` is honored; otherwise macOS uses Safari's exact UA (installed Safari version) so Google doesn't reject the window as an insecure browser.
    - macOS: `macos/Runner/WebAuthWindow.swift` (WKWebView, `WKWebsiteDataStore.nonPersistent()`, `WKHTTPCookieStore`).
    - Linux: `linux/runner/web_auth.cc` loads WebKitGTK 4.1 with `dlopen` (ephemeral `WebKitWebContext`), so the app neither builds against nor requires it. Without it the dialog shows the paste flow.
    - Android: 📋 not yet (WebView dialog with the `; wv` UA marker stripped), so the paste flow is shown.
    - Fallback everywhere: **Advanced: paste cookies** (open the URL in a browser, paste a cURL command, Cookie header or JSON).
    - `integration_test/web_auth_test.dart` opens Google's and Slack's sign-in pages in the real window and checks they load and aren't blocked (no credentials entered).
  - `complete`.
- **Capability flags** ✅ (`PlatformCapabilities`): `canExtractAppleHardwareKey` (macOS), `hasPersistentSyncService` (Android), `hasEmbeddedWebview`, `isMobile`. Manifest `requirements.provided_by` is matched against the current platform.
- **Backends.** `FfiBackend` (Rust core) by default. `DemoBackend` (sample data) runs with `CROSSCHAT_DEMO=1` or `--dart-define=CROSSCHAT_DEMO=true`, and is used when the native library fails to load.

## 7. Notifications and mobile
- **Push is deferred to a paid tier.** It needs an operated push gateway (APNs and FCM keys belong to the app publisher), a privacy policy, and an iOS Notification Service Extension. 📋
- **Android: opt-in persistent sync** ✅ (alpha). Settings → "Keep connection open" starts a `remoteMessaging` foreground service with a minimum-importance ongoing notification, so the process and the Rust sync loop keep running in the background without push. ⚠️ Alpha limitation: the sync loop lives in the activity's Flutter engine, so swiping the app away stops it. 📋 Move the loop into the service. ⚠️ Behavior under deep Doze is unverified.
- **Future relay (documented only, not built).** A ~$1/mo **TLS-passthrough relay** for people without a public IP or Tailscale. It forwards raw TLS (SNI routing) to the user's home server, so the relay never sees plaintext or holds certificates. It would also be the natural home for the paid push gateway.

## 8. Security model
- The **host sees plaintext**: bridges decrypt Matrix events to re-send them to the remote network, and vice versa. This is inherent to bridging. Run the host on hardware you trust.
- **Appservice tokens** can impersonate everyone in their namespace. The **double-puppet token** can puppet *all* local users and is the most sensitive secret. Both live only in the vault.
- **Bridges bind to loopback.** Only `crosschatd` is exposed, through the reverse proxy, at `/_crosschat`. Clients never see provisioning secrets. The proxy always forces `user_id` to the authenticated caller.
- **Supply chain.** Versions are pinned and every artifact's checksum is pinned (no TOFU). Crosschat-built assets are reproducible from `scripts/build-prebuilt.sh`; the Linux ones match bit-for-bit on the same toolchain. 📋 Signed manifests, Developer ID signing and notarization of the macOS app.

## 9. Licensing
- **Our code is Apache-2.0.**
- **Bridges are never vendored.** Their source isn't in this repo, and they run unmodified as separate processes talking HTTP. Binaries come from upstream releases, or from Crosschat's `prebuilt-vN` builds of unmodified upstream source. Distributing those builds, and bundling gmessages/slack in the macOS app, is AGPL distribution: the release notes link the exact upstream tag or commit (the corresponding source), and the same goes for any future image or installer.
- Tuwunel and Continuwuity are Apache-2.0. matrix-rust-sdk is Apache-2.0. flutter_rust_bridge is MIT.

## 10. Risks and gaps
- **Scope.** Four networks, a daemon, a bundled homeserver, and five client platforms is a lot for a small team. Mitigations: bridgev2 everywhere, so one login renderer and one proxy cover all four; manifests instead of per-bridge code; a strict "no fake features" policy.
- **Bridge-host decryption.** See §8. It's unavoidable with bridges, and must be communicated clearly in onboarding.
- **Account bans and ToS.** Apple, Google, Slack, and GroupMe can flag or ban unofficial clients. iMessage via corten-matrix and Google Messages via cookies are the most fragile. The app shows maturity badges and preflight warnings.
- **Maintenance churn.** Upstream bridges, Google's cookie rotation, Apple's protocol changes, matrix-rust-sdk pre-1.0 APIs, and the bridgev2 provisioning API all move. Mitigation: pinned versions, a manifest per bridge, the end-to-end smoke test in CI-like scripts, and our facade crate as the only Rust API Dart sees.
- **Onboarding.** ✅ No homeserver needed to start: the local server on this computer. Still hard for a real server: reverse proxy, server name, federation choice. Plus a Mac for the iMessage key. A real-server wizard and local-to-real migration are the biggest UX gaps 📋.
- **GroupMe** has no upstream releases and is early. iMessage has no published checksums.
- **Threads.** There is no standard "also send to channel" yet, and there is no cross-room thread inbox in the alpha.

## 11. Roadmap
1. **Alpha (this repo):** core, daemon, 4 manifests, Flutter UI, end-to-end smoke test, CI.
2. **Daily-drivable:** E2EE verification and recovery, media, reactions, read receipts, sliding sync, keychain storage, room list performance.
3. **Logins without a terminal:** real-account testing of all four networks, the sign-in window on Android, a bridge health screen, logout and relogin.
4. **Setup wizard:** ✅ local server on this computer (owner bootstrap, server_name lock-in warning). 📋 Real-server flow (server name, federation choice), migrating a local server to a real domain ([#1](https://github.com/devonkinghorn/crosschat/issues/1)), reverse proxy recipes, Docker image.
5. **Mobile:** sync loop in the Android service, iOS build, then the paid push tier and relay.
6. **More networks:** WhatsApp, Signal, Telegram.
