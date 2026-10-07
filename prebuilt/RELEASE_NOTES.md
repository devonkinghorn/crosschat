Prebuilt binaries for Crosschat, so nobody has to compile anything to run it. **Not a Crosschat app release.**

crosschatd downloads these on demand and checks the SHA-256 pinned in `manifests/*.yaml` and `crates/crosschatd/src/tuwunel.rs` (also listed in `prebuilt/SHA256SUMS`). The macOS app bundles the default-on ones. Each asset is a single zstd-compressed executable.

| Asset | What | Built from (unmodified upstream source) | License |
|---|---|---|---|
| `mautrix-gmessages-v0.2609.0-darwin-{arm64,amd64}.zst` | Google Messages bridge for macOS | [mautrix/gmessages@v0.2609.0](https://github.com/mautrix/gmessages/tree/v0.2609.0), `-tags goolm` | AGPL-3.0 |
| `mautrix-slack-v0.2609.1-darwin-{arm64,amd64}.zst` | Slack bridge for macOS | [mautrix/slack@v0.2609.1](https://github.com/mautrix/slack/tree/v0.2609.1), `-tags goolm` | AGPL-3.0 |
| `mautrix-groupme-ff4fbcc6211d-{darwin,linux}-{arm64,amd64}.zst` | GroupMe bridge (no upstream releases) | [beeper/groupme@ff4fbcc](https://github.com/beeper/groupme/tree/ff4fbcc6211d7e24fb0c240f6dc15e95555962db), `-tags goolm`, static musl on Linux | AGPL-3.0 |
| `tuwunel-v1.9.3-darwin-{arm64,amd64}.zst` | Tuwunel homeserver for macOS (upstream ships Linux only) | [matrix-construct/tuwunel@v1.9.3](https://github.com/matrix-construct/tuwunel/tree/v1.9.3), upstream default features minus `io_uring`, `systemd`, `jemalloc` | Apache-2.0 |

Why these exist: upstream mautrix darwin binaries link Homebrew's `libolm`, which Homebrew no longer ships. These builds use the pure-Go olm instead and depend only on macOS system libraries. Minimum macOS is 13 for the bridges (Go 1.27) and 12 for Tuwunel. Linux gmessages/slack, Linux Tuwunel and corten-matrix (iMessage) come straight from their upstream releases.

Reproduce with [`scripts/build-prebuilt.sh`](https://github.com/devonkinghorn/crosschat/blob/main/scripts/build-prebuilt.sh) (pins are at the top), or run the `prebuilt-*` CI jobs (`ci/github-actions-ci.yml`, manual dispatch with `prebuilt_tag`). Go builds use `-trimpath`, `-buildvcs=false` and the commit time as build time. The Linux builds reproduce bit-for-bit on the same toolchain.
