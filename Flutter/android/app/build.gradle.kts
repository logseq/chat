plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val repoRoot = rootProject.projectDir.parentFile.parentFile
val flutterNativeLibrary = repoRoot.resolve(
    "Flutter/android/app/src/main/jniLibs/arm64-v8a/liblogseq_chat_core.so",
)

tasks.register<Exec>("buildAndroidNativeCore") {
    workingDir = repoRoot
    commandLine("bash", "scripts/build-android-native.sh")
    inputs.files(
        fileTree(repoRoot.resolve("core")),
        fileTree(repoRoot.resolve("lg")),
        fileTree(repoRoot.resolve("datascript-ocaml-native")),
        repoRoot.resolve("scripts/bootstrap-android-ocaml.sh"),
        repoRoot.resolve("scripts/build-android-native.sh"),
        repoRoot.resolve("scripts/build-android-sqlite.sh"),
        repoRoot.resolve("scripts/build-mobile-ocaml.sh"),
    )
    outputs.file(flutterNativeLibrary)
}

tasks.named("preBuild") {
    dependsOn("buildAndroidNativeCore")
}

dependencies {
    implementation("androidx.browser:browser:1.8.0")
    implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20251224")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}

android {
    namespace = "com.logseq.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.logseq.chat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
