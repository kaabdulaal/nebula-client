plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("com.google.firebase.crashlytics")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nebula.nebula_client"
    
    compileSdk = 35
    
    ndkVersion = System.getenv("ANDROID_NDK_HOME")?.split("/")?.lastOrNull()
        ?: "26.1.10909125"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.nebula.nebula_client"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        // Limit the NDK build to arm64-v8a since we only have vcpkg deps for that installed
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")

            // R8 / ProGuard:
            // MUST have proguard-rules.pro to protect JNI bridge symbols
            // (nebula_core.so, libtdjson.so) from being stripped or renamed.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // ── Firebase Crashlytics (Native C++ Symbols) ────────────────────
            configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                nativeSymbolUploadEnabled = true
                unstrippedNativeLibsDir = "build/intermediates/merged_native_libs/release/out/lib"
            }
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../../nebula_core/CMakeLists.txt")
        }
    }
    
    // CRITICAL: Force clean build directory before assembling to remove old artifacts
    // Note: If build issues persist, run 'flutter clean' manually.
    applicationVariants.all {
        val variantName = name.capitalize()
        val taskName = "assemble$variantName"
        tasks.findByName(taskName)?.doFirst {
           // Rely on standard cleaning or timestamp updates in CMakeLists.txt
           // Explicit deletion here caused 'no such file' errors in some environments.
           println("Ensure native libs are updated by checking CMakeLists.txt version.")
        }
    }
}

flutter {
    source = "../.."
}
