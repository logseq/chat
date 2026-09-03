// This gradle project is part of a conventional Skip app project.
pluginManagement {
    // Initialize the Skip plugin folder and perform a pre-build for non-Xcode builds
    val pluginPath = File.createTempFile("skip-plugin-path", ".tmp")

    // overriding outputs for an Android IDE can be done by un-commenting and setting the Xcode path:
    //System.setProperty("BUILT_PRODUCTS_DIR", "${System.getProperty("user.home")}/Library/Developer/Xcode/DerivedData/MySkipProject-HASH/Build/Products/Debug-iphonesimulator")

    val skipPluginResult = providers.exec {
        // Xcode `xcrun` is required for Skip's iOS prebuild. On Linux emulator
        // hosts, fall back to `--no-prebuild` and consume existing skipstone output.
        commandLine(
            "/bin/sh",
            "-c",
            """
            if command -v xcrun >/dev/null 2>&1; then
              skip plugin --prebuild --package-path '${settings.rootDir.parent}' --plugin-ref '${pluginPath.absolutePath}'
            else
              skip plugin --no-prebuild --package-path '${settings.rootDir.parent}' --plugin-ref '${pluginPath.absolutePath}'
            fi
            """.trimIndent()
        )
        environment("PATH", "${System.getenv("PATH")}:/opt/homebrew/bin:${System.getProperty("user.home")}/opt/skip/skip.artifactbundle/bin")
    }
    val skipPluginOutput = skipPluginResult.standardOutput.asText.get()
    print(skipPluginOutput)
    val skipPluginError = skipPluginResult.standardError.asText.get()
    print(skipPluginError)

    includeBuild(pluginPath.readText()) {
        name = "skip-plugins"
    }
}

plugins {
    id("skip-plugin") apply true
}
