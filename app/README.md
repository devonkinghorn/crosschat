# Crosschat app

Flutter UI for Crosschat. The Rust core is bound via flutter_rust_bridge (`rust/` = `crosschat_ffi`, built automatically by cargokit).

```bash
flutter run -d linux                    # real Rust core
CROSSCHAT_DEMO=1 flutter run -d linux   # demo data
flutter analyze && flutter test
```

Regenerate bindings after changing `rust/src/api/*.rs`:

```bash
flutter_rust_bridge_codegen generate
```

See the [top-level README](../README.md).
