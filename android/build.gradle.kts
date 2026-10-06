plugins {
    id("com.android.application") version "9.1.0" apply false
    id("com.android.library") version "9.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
}

// :lui is the real LUI Kotlin backend included from ../lui/platform/android.
// Its own test suite (paparazzi screenshot tests) needs the standalone
// platform/android build — disable it here so ./gradlew test only runs
// the app's tests.
project(":lui").tasks.withType<Test>().configureEach {
    enabled = false
}
