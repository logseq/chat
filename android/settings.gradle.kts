pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// The Kotlin/Jetpack Compose LUI backend is developed in the logseq/lui
// checkout at ../lui (platform/android on branch devin/android-kotlin).
// When that build exists it is consumed as a composite build, mirroring
// how apple/ path-deps ../lui/platform/apple. Until it lands, the app
// builds against the interim dev.lui implementation vendored in :lui —
// it implements the documented dev.lui surface (LuiBackend patch/node
// store, LuiTheme, node renderers, LuiExtensionRegistry) so swapping it
// for the real backend is a settings-only change.
val luiCheckoutBuild = File(rootDir, "../../lui/platform/android")
val useCheckoutLui = luiCheckoutBuild.isDirectory &&
    File(luiCheckoutBuild, "settings.gradle.kts").isFile

if (useCheckoutLui) {
    includeBuild(luiCheckoutBuild)
} else {
    include(":lui")
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

include(":app")
