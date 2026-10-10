pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// The Kotlin/Jetpack Compose LUI backend is consumed as an included
// module from the logseq/lui checkout at ../lui/platform/android/lui —
// the same consumption model as lui's own
// examples/components/android app, mirroring how apple/ path-deps
// ../lui/platform/apple. The module resolves plugins from this build's
// classpath (AGP 9 + builtInKotlin).
val luiModuleDir = listOf(
    File(rootDir, "../../lui/platform/android/lui"),
    File(rootDir, "../duniverse/lui/platform/android/lui"),
).firstOrNull { it.isDirectory && File(it, "build.gradle.kts").isFile }
require(luiModuleDir != null) {
    "Expected a logseq/lui checkout at ../lui or duniverse/lui with platform/android/lui"
}

include(":lui")
project(":lui").projectDir = luiModuleDir

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

include(":app")
