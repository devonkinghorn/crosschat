plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.crosschat.crosschat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.crosschat.crosschat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Keeps rustls-platform-verifier's Kotlin part (only called from Rust via JNI).
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// rustls-platform-verifier (HTTPS certificate checks in the Rust core) has a
// small Kotlin part, published as a Maven repo on GitHub. Its version must
// match the `rustls-platform-verifier-android` crate in the repo's Cargo.lock.
repositories {
    maven {
        url = uri("https://github.com/rustls/rustls-platform-verifier/raw/maven-archive/android-release-support/maven/")
        content { includeGroup("org.rustls") }
    }
}

val rustlsPlatformVerifierVersion: String = run {
    val crate = "rustls-platform-verifier-android"
    val lines = file("../../../Cargo.lock").readLines()
    val idx = lines.indexOfFirst { it.trim() == "name = \"$crate\"" }
    require(idx >= 0) { "$crate not found in Cargo.lock" }
    lines.drop(idx + 1).first { it.trimStart().startsWith("version = ") }.substringAfter('"').substringBefore('"')
}

dependencies {
    implementation("org.rustls:rustls-platform-verifier:$rustlsPlatformVerifierVersion")
}
