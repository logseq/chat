import Testing
@testable import LogseqChat

@Suite struct LogseqThemeSettingsTests {
    @Test func classicPaletteMatchesTheOfficialLogseqThemeTokens() {
        #expect(LogseqThemePolicy.light.backgroundHex == "#FCFCFC")
        #expect(LogseqThemePolicy.light.surfaceHex == "#F8F8F8")
        #expect(LogseqThemePolicy.light.primaryTextHex == "#171717")
        #expect(LogseqThemePolicy.dark.backgroundHex == "#002D38")
        #expect(LogseqThemePolicy.dark.surfaceHex == "#19394D")
        #expect(LogseqThemePolicy.dark.primaryTextHex == "#EDFDFD")
        #expect(LogseqThemePolicy.accentHex == "#037DBA")
    }

    @Test func appearanceModesResolveWithoutDuplicatingSystemState() {
        #expect(LogseqThemeMode(rawValue: "system") == .system)
        #expect(LogseqThemeMode(rawValue: "light") == .light)
        #expect(LogseqThemeMode(rawValue: "dark") == .dark)
        #expect(LogseqThemeMode(rawValue: "unknown") == nil)
    }

    @Test func languageChoicesCoverEveryShippedLocalization() {
        #expect(LogseqSettingsPolicy.languages.map(\.id) == [
            "system", "en", "zh-Hans", "ja", "fr", "es",
        ])
    }

    @Test func customSyncServerAcceptsOnlyHttpURLsAndNormalizesWhitespace() {
        #expect(
            LogseqSettingsPolicy.normalizedSyncServerURL(" https://sync.example.com/path ")
                == "https://sync.example.com/path"
        )
        #expect(
            LogseqSettingsPolicy.normalizedSyncServerURL("http://127.0.0.1:8787")
                == "http://127.0.0.1:8787"
        )
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("ftp://example.com") == nil)
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("example.com") == nil)
        #expect(LogseqSettingsPolicy.normalizedSyncServerURL("   ") == nil)
    }

    @Test func communityAndSupportDestinationsMatchLogseqMobile() {
        #expect(LogseqSettingsPolicy.communityLinks.map(\.title) == [
            "Report bug", "Discord community", "Forum", "GitHub",
        ])
        #expect(LogseqSettingsPolicy.communityLinks.allSatisfy { $0.url.scheme == "https" })
    }
}
