//! HTTPS certificate checks on Android.
//!
//! matrix-sdk's HTTP client (reqwest + rustls) verifies server certificates
//! with `rustls-platform-verifier`, which asks Android's own trust manager
//! (system CAs, the app's network security config). That needs the app
//! context, handed over once at startup by `RustTls.ensure(context)` in
//! `MainActivity` before any request. Without it every HTTPS request fails.

use jni::EnvUnowned;
use jni::errors::ThrowRuntimeExAndDefault;
use jni::objects::{JClass, JObject};

#[unsafe(no_mangle)]
pub extern "system" fn Java_app_crosschat_crosschat_RustTls_nativeInit<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    context: JObject<'caller>,
) {
    env.with_env(|env| rustls_platform_verifier::android::init_with_env(env, context))
        .resolve::<ThrowRuntimeExAndDefault>();
}
