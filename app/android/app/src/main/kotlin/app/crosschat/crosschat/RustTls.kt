package app.crosschat.crosschat

import android.content.Context

/**
 * Hands the app context to the Rust core so its HTTPS client can check
 * certificates with Android's trust manager (rustls-platform-verifier).
 * Must run before the first request; see app/rust/src/android_tls.rs.
 */
object RustTls {
    @Volatile private var done = false

    @Synchronized
    fun ensure(context: Context) {
        if (done) return
        System.loadLibrary("crosschat_ffi")
        nativeInit(context.applicationContext)
        done = true
    }

    @JvmStatic private external fun nativeInit(context: Context)
}
