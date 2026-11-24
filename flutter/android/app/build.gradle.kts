plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.faria2177.pdf_studio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.faria2177.pdf_studio"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // doclens (DocScanner camera) needs API 24.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Phones only: OpenCV and ML Kit would otherwise add ~75 MB of x86_64 libraries.
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    packaging {
        resources {
            // PdfBox's BouncyCastle post-quantum tables (~7 MB) are never used for PDF encryption.
            excludes += "org/bouncycastle/pqc/**"
        }
    }

    // Android lint crashes inside camera_android_camerax (AnalyzerProxyApi.java,
    // "bug in lint"); it only blocks release packaging, so skip the release lint gate.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Keep rules for JNI/reflection users (Tesseract, PdfBox, doclens, ML Kit).
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

dependencies {
    // Encryption ("Protect a PDF") and image recompression ("Compress a PDF").
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    implementation("androidx.core:core-ktx:1.15.0")
    // OCR (Tesseract 5 + Leptonica), from JitPack.
    implementation("cz.adaptech.tesseract4android:tesseract4android:4.9.0")
}
