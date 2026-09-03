import java.util.Properties

plugins {
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.android.application)
    id("skip-build-plugin")
}

skip {
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation(kotlin("test-junit"))
    testImplementation("org.json:json:20251224")
    androidTestImplementation("androidx.test:runner:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

configurations.configureEach {
    exclude(group = "com.google.guava", module = "listenablefuture")
}

val repoRoot = rootProject.projectDir.parentFile
// Supported ABIs: arm64-v8a for devices, x86_64 for the Android emulator VM.
val androidNativeAbis = (System.getenv("LOGSEQ_CHAT_ANDROID_ABIS")
    ?: System.getenv("LOGSEQ_CHAT_ANDROID_ABI")
    ?: "arm64-v8a")
    .split(Regex("[,\\s]+"))
    .map { it.trim() }
    .filter { it.isNotEmpty() }
    .distinct()

val androidNativeCoreTasks = androidNativeAbis.map { abi ->
    tasks.register<Exec>("buildAndroidNativeCore_${abi.replace('-', '_')}") {
        workingDir = repoRoot
        environment("LOGSEQ_CHAT_ANDROID_ABI", abi)
        listOf(
            "ANDROID_HOME",
            "ANDROID_SDK_ROOT",
            "ANDROID_NDK_HOME",
            "LOGSEQ_CHAT_BUILD_JOBS"
        ).forEach { key ->
            System.getenv(key)?.let { value -> environment(key, value) }
        }
        commandLine("bash", "scripts/build-android-native.sh")
    }
}

tasks.register("buildAndroidNativeCore") {
    dependsOn(androidNativeCoreTasks)
}

tasks.named("preBuild") {
    dependsOn("buildAndroidNativeCore")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(libs.versions.jvm.get().toString())
    }
}

android {
    namespace = group as String
    compileSdk = libs.versions.android.sdk.compile.get().toInt()
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
        targetCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
    }
    packaging {
        jniLibs {
            keepDebugSymbols.add("**/*.so")
            pickFirsts.add("**/*.so")
            // this option would compress JNI .so files and reduce overall size for Skip Fuse apps, but cost more at install time
            //useLegacyPackaging = true
        }
    }

    defaultConfig {
        minSdk = libs.versions.android.sdk.min.get().toInt()
        targetSdk = libs.versions.android.sdk.compile.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // skip.tools.skip-build-plugin will automatically use Skip.env properties for:
        // applicationId = ANDROID_APPLICATION_ID ?? PRODUCT_BUNDLE_IDENTIFIER
        // versionCode = CURRENT_PROJECT_VERSION
        // versionName = MARKETING_VERSION
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        disable.add("Instantiatable")
        disable.add("MissingPermission")
    }

    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }

    // default signing configuration tries to load from keystore.properties
    // see: https://skip.dev/docs/deployment/#export-signing
    signingConfigs {
        val keystorePropertiesFile = file("keystore.properties")
        create("release") {
            if (keystorePropertiesFile.isFile) {
                val keystoreProperties = Properties()
                keystoreProperties.load(keystorePropertiesFile.inputStream())
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            } else {
                // when there is no keystore.properties file, fall back to signing with debug config
                keyAlias = signingConfigs.getByName("debug").keyAlias
                keyPassword = signingConfigs.getByName("debug").keyPassword
                storeFile = signingConfigs.getByName("debug").storeFile
                storePassword = signingConfigs.getByName("debug").storePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false // can be set to true for debugging release build, but needs to be false when uploading to store
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
