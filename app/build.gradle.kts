plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Set by CI from the upstream release tag (e.g. "0.21.1").
val upstreamVersion: String = (project.findProperty("upstreamVersion") as String?) ?: "0.0.0"
val buildNumber: Int = ((project.findProperty("buildNumber") as String?) ?: "1").toInt()

android {
    namespace = "com.jahid2177.pdftools"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.jahid2177.pdftools"
        minSdk = 26
        targetSdk = 35
        versionCode = buildNumber
        versionName = upstreamVersion
    }

    signingConfigs {
        create("release") {
            storeFile = file("../release.jks")
            storePassword = System.getenv("KEYSTORE_PASSWORD") ?: "pdftools123"
            keyAlias = "pdftools"
            keyPassword = System.getenv("KEYSTORE_PASSWORD") ?: "pdftools123"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    androidResources {
        // .wasm / .onnx must stay readable as streams; don't let aapt skip hidden files either.
        ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:!CVS:!thumbs.db:!picasa.ini:!*~"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
}
