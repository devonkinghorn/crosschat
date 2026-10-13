# rustls-platform-verifier: called from Rust through JNI only, so R8 can't see it.
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
# RustTls.nativeInit is implemented in libcrosschat_ffi.so.
-keepclasseswithmembernames class app.crosschat.crosschat.RustTls { native <methods>; }
