import java.security.KeyStore
import java.security.PrivateKey
import java.security.MessageDigest
import java.security.cert.X509Certificate

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Opt-in, explicitly requested test builds only, enabled by adding
// allowTestSigning=true to android/gradle.properties. Production builds never
// set it: without it the release variant still uses the CI keystore and
// validateProductionSigning still gates release packaging. A test build is
// release mode (AOT, so motion behaves like production) but carries the
// runner's debug signature, which is why it can never be distributed.
val allowTestSigning = (project.findProperty("allowTestSigning") as? String) == "true"

android {
    namespace = "com.tutorsdesk.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tutorsdesk.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing from CI secrets. The keystore + passwords are restored
    // by the GitHub workflow. Release NEVER falls back to a development key.
    signingConfigs {
        create("release-ci") {
            val ksFile = File(projectDir, "release.keystore")
            storeFile = ksFile
            storeType = "PKCS12"
            storePassword = System.getenv("RELEASE_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("RELEASE_KEY_ALIAS")
            keyPassword = System.getenv("RELEASE_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (allowTestSigning) "debug" else "release-ci",
            )

            // Strip unused Java/Kotlin classes and shrink bundled resources.
            // Flutter ships default ProGuard rules for its own engine bindings.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources {
            // Duplicate licence/metadata files from bundled Java libraries.
            excludes += setOf(
                "META-INF/*.kotlin_module",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/AL2.0",
                "META-INF/LGPL2.1",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The app module needs the Google Play services API at compile time
    // (MainActivity's scanner pre-flight check + module download). Both
    // artifacts are already bundled at runtime by the ML Kit plugin;
    // these only expose the classes to the app's Kotlin.
    // FileProvider for handing a downloaded app update to the installer.
    implementation("androidx.core:core:1.13.1")
    implementation("com.google.android.gms:play-services-base:18.1.0")
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
}

flutter {
    source = "../.."
}

// Executed for every release packaging path, not only the CI command.
val validateProductionSigning = tasks.register("validateProductionSigning") {
    doLast {
        val required = listOf("RELEASE_KEYSTORE_PASSWORD", "RELEASE_KEY_ALIAS", "RELEASE_KEY_PASSWORD", "RELEASE_CERT_SHA256")
        check(required.all { !System.getenv(it).isNullOrBlank() } && File(projectDir, "release.keystore").isFile) {
            "Production release signing is incomplete. Configure the existing release keystore and certificate pin; no fallback APK will be built."
        }
        val store = KeyStore.getInstance("PKCS12")
        File(projectDir, "release.keystore").inputStream().use {
            store.load(it, System.getenv("RELEASE_KEYSTORE_PASSWORD").toCharArray())
        }
        val alias = System.getenv("RELEASE_KEY_ALIAS")
        val cert = store.getCertificate(alias) as? X509Certificate
            ?: error("Release signing certificate was not found.")
        check(store.getKey(alias, System.getenv("RELEASE_KEY_PASSWORD").toCharArray()) is PrivateKey) {
            "Release signing requires a private key."
        }
        check(!alias.equals("androiddebugkey", ignoreCase = true) &&
            !cert.subjectX500Principal.name.contains("Android Debug", ignoreCase = true)) {
            "Debug certificates are forbidden for production releases."
        }
        cert.checkValidity()
        val actual = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
            .joinToString("") { "%02x".format(it) }
        val expected = System.getenv("RELEASE_CERT_SHA256").replace(":", "").lowercase().trim()
        check(expected.matches(Regex("[0-9a-f]{64}")) && actual == expected) {
            "Release certificate does not match the approved SHA-256 pin."
        }
    }
}
tasks.configureEach {
    // A test build opts out of the production signing gate; everything else,
    // including every tag and every default release build, stays gated.
    if ((name == "preReleaseBuild" || name == "validateSigningRelease") && !allowTestSigning) {
        dependsOn(validateProductionSigning)
    }
}
