import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials live in android/key.properties, which is not
// committed. Without that file the build falls back to the debug keys so a
// fresh clone still runs.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.mytv.my_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.mytv.my_tv"
        // Flutter's default, currently 24 (Android 7.0).
        //
        // This can be lowered to 21 for the Android 5 and 6 car head units
        // and TV boxes still in use: 21 is the real floor, set by the jni
        // packages media_kit depends on. file_selector_android declares 24,
        // but that is the Flutter plugin template's default rather than a
        // real requirement - it calls only ACTION_OPEN_DOCUMENT, available
        // since API 19, and version-checks its one API 26 feature at runtime
        // - so AndroidManifest.xml already carries the tools:overrideLibrary
        // that allows it, and the file picker in add_source_page.dart is
        // wrapped so an older device shows a message instead of crashing.
        // Change this line to `minSdk = 21` to take it.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Left off deliberately: libmpv is reached over JNI, and R8 has no
            // way to see those references.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // FileProvider, used to hand the downloaded update to the installer.
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
