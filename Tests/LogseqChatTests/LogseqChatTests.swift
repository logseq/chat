import Testing
import Foundation
@testable import LogseqChat

@Suite struct LogseqChatTests {

    @Test func logseqChat() throws {
        #expect(1 + 2 == 3, "basic test")
    }

    @Test func appleAppUsesAmplifyAuthenticatorInsteadOfCustomLoginUI() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/LogseqChatApp.swift"),
            encoding: .utf8
        )
        let provider = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/CognitoAuthProvider.swift"),
            encoding: .utf8
        )
        let androidProvider = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/Skip/CognitoAuthProvider.kt"),
            encoding: .utf8
        )
        let skipConfiguration = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/Skip/skip.yml"),
            encoding: .utf8
        )

        #expect(app.contains("import Authenticator"))
        #expect(app.contains("Authenticator {"))
        #expect(content.contains("#if SKIP"))
        #expect(content.contains("LogseqLoginView"))
        #expect(!content.contains("#if !SKIP\n                LogseqLoginView"))
        #expect(!content.contains("field.pat"))
        #expect(provider.contains("import Amplify"))
        #expect(provider.contains("AuthCognitoTokensProvider"))
        #expect(provider.contains("Amplify.Auth.fetchAuthSession()"))
        #expect(provider.contains("tokens.accessToken"))
        #expect(!provider.contains("AWSCognitoIdentityUserPool"))
        #expect(androidProvider.contains("CognitoUserPool"))
        #expect(androidProvider.contains("session.accessToken?.jwtToken"))
        #expect(skipConfiguration.contains("aws-android-sdk-cognitoidentityprovider"))
        #expect(!skipConfiguration.contains("com.amplifyframework"))
    }

    @Test func appleAuthDependsOnlyOnAmplifyCognitoAndAuthenticatorProducts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let provider = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/CognitoAuthProvider.swift"),
            encoding: .utf8
        )

        #expect(package.contains("https://github.com/aws-amplify/amplify-swift"))
        #expect(package.contains("https://github.com/aws-amplify/amplify-ui-swift-authenticator"))
        #expect(package.contains(".product(name: \"Amplify\""))
        #expect(package.contains(".product(name: \"AWSPluginsCore\""))
        #expect(package.contains(".product(name: \"AWSCognitoAuthPlugin\""))
        #expect(package.contains(".product(name: \"Authenticator\""))
        #expect(!package.contains("Vendor/LogseqCognitoSDK"))
        #expect(!package.contains("AWSAPIPlugin"))
        #expect(!package.contains("AWSS3StoragePlugin"))
        #expect(!package.contains("AWSDataStorePlugin"))
        #expect(!provider.contains("refreshToken"))
    }

    @Test func amplifyAuthUsesTheExistingUserPoolAndManagedSessionLifecycle() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/LogseqChatApp.swift"),
            encoding: .utf8
        )
        let provider = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/CognitoAuthProvider.swift"),
            encoding: .utf8
        )

        #expect(app.contains("AmplifyOutputsData"))
        #expect(app.contains("AWSCognitoAuthPlugin()"))
        #expect(app.contains("userPoolId:"))
        #expect(app.contains("userPoolClientId:"))
        #expect(app.contains("passwordPolicy: .init("))
        #expect(app.contains("minLength: 8"))
        #expect(app.contains("requireNumbers: true"))
        #expect(app.contains("requireLowercase: true"))
        #expect(app.contains("requireUppercase: true"))
        #expect(app.contains("requireSymbols: true"))
        #expect(app.contains("try Amplify.configure"))
        #expect(provider.contains("Amplify.Auth.signOut()"))
        #expect(provider.contains("Amplify.Auth.signIn"))
        #expect(!provider.contains("Keychain"))
    }

    @Test func amplifyAuthAndE2EUseTheCognitoUsername() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/LogseqChatApp.swift"),
            encoding: .utf8
        )
        let captureFlow = try String(
            contentsOf: root.appendingPathComponent(".maestro/ios-capture-responsive.yaml"),
            encoding: .utf8
        )
        let realtimeFlow = try String(
            contentsOf: root.appendingPathComponent(".maestro/ios-local-realtime-sync.yaml"),
            encoding: .utf8
        )

        #expect(!app.contains("usernameAttributes: [.email]"))
        for flow in [captureFlow, realtimeFlow] {
            #expect(flow.contains("Enter your username"))
            #expect(!flow.contains("Enter your email"))
        }
    }

    @Test func realtimeE2EAllowsAnExistingAmplifySession() throws {
        let flowURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".maestro/ios-local-realtime-sync.yaml")
        let flow = try String(contentsOf: flowURL, encoding: .utf8)

        #expect(flow.contains("runFlow:"))
        #expect(flow.contains("when:"))
        #expect(flow.contains("visible: \"Enter your username\""))
        #expect(flow.contains("id: \"screen.graph-picker\""))
    }

    @Test func signedInAppRequiresExplicitUnencryptedGraphSelection() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )

        #expect(content.contains("screen.graph-picker"))
        #expect(content.contains("store.snapshot.selectedGraphId == nil"))
        #expect(content.contains("store.selectGraph(graph.id)"))
        #expect(content.contains("graph.isEncrypted || !graph.isReady"))
    }

    @Test func graphPickerExposesConnectionSettingsBeforeGraphSelection() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let pickerStart = try #require(content.range(of: "private var graphPicker: some View"))
        let remaining = content[pickerStart.lowerBound...]
        let pickerEnd = try #require(remaining.range(of: "\n\n    @ViewBuilder private var appShell"))
        let picker = remaining[..<pickerEnd.lowerBound]
        let connectStart = try #require(content.range(of: "private func connectWithCurrentAccessToken()"))
        let connectRemaining = content[connectStart.lowerBound...]
        let connectEnd = try #require(connectRemaining.range(of: "\n\n    @ViewBuilder private var authenticatedContent"))
        let connect = connectRemaining[..<connectEnd.lowerBound]

        #expect(picker.contains("settingsControl"))
        #expect(picker.contains("authentication.errorMessage"))
        #expect(picker.contains("store.lastError"))
        #expect(picker.contains("ErrorBanner(error: error)"))
        #expect(!connect.contains("try? await authentication.accessToken()"))
        #expect(connect.contains("logger.error"))
        #expect(connect.contains("#if DEBUG"))
        #expect(connect.contains("print("))

        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChatModel/ViewModel.swift"),
            encoding: .utf8
        )
        #expect(model.contains("LogseqChat debug: core action failed"))
        #expect(model.contains("LogseqChat debug: core action applied"))
    }

    @Test func failedSnapshotBootstrapDoesNotStartGraphEvents() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(content.range(of: "private func startGraphSync(_ graphID: String)"))
        let remaining = content[start.lowerBound...]
        let end = try #require(remaining.range(of: "\n\n    private var appBackground"))
        let graphSync = remaining[..<end.lowerBound]

        #expect(graphSync.contains("guard await store.bootstrapSelectedGraph("))
        #expect(graphSync.contains("else { return }"))
    }

    @Test func restoredGraphIsRediscoveredBeforeSyncStarts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(content.range(of: "private func connectWithCurrentAccessToken()"))
        let remaining = content[start.lowerBound...]
        let end = try #require(remaining.range(of: "\n\n    @ViewBuilder private var authenticatedContent"))
        let connect = remaining[..<end.lowerBound]

        #expect(connect.contains("await store.configureAndSelectGraph("))
        #expect(!connect.contains("store.configure("))
    }

    @Test func decodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try #require(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        #expect(testData.testModuleName == "LogseqChat")
    }

    #if !SKIP
    @Test func headerAndFooterDoNotDrawBackgroundChrome() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(".platformHeaderGlassBackground()"))
        #expect(source.contains(".platformHeaderChrome()"))
        #expect(!source.contains("Logseq chat app"))
        #expect(source.contains("settingsControl"))
        #expect(source.contains("IconImage(name: \"more_horiz\")"))
        #expect(source.contains(".platformFloatingHeaderInset()"))
    }

    @Test func androidHeaderControlsKeepCapsuleShape() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("#else\n        self.background(Color.white.opacity(0.82))\n            .cornerRadius(26)\n        #endif"))
    }

    @Test func settingsControlUsesCircularGlassButton() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let controlStart = try #require(source.range(of: "private var settingsControl: some View"))
        let remainingSource = source[controlStart.lowerBound...]
        let controlEnd = try #require(remainingSource.range(of: "\n    private var searchBar: some View"))
        let controlSource = remainingSource[..<controlEnd.lowerBound]

        #expect(controlSource.contains(".frame(width: 52, height: 52)"))
        #expect(controlSource.contains(".platformGlassButtonStyle()"))
        #expect(controlSource.contains(".platformCircleButtonShape()"))
        #expect(!controlSource.contains(".platformGlassCapsule()"))
    }

    @Test func settingsExportsTheSelectedGraphSQLiteDatabase() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("graphDatabasePath: selectedGraphDatabasePath"))
        #expect(source.contains("private var selectedGraphDatabasePath: String?"))
        #expect(source.contains("appendingPathComponent(\"graphs\")"))
        #expect(source.contains("appendingPathComponent(\"graph.sqlite\")"))
        #expect(source.contains("ShareLink(item: graphDatabaseURL)"))
        #expect(source.contains("Text(\"Export Graph SQLite DB\")"))
    }

    @Test func iosDeclaresAndSchedulesBackgroundRefresh() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let plistData = try Data(contentsOf: root.appendingPathComponent("Darwin/Info.plist"))
        let plistValue = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        let plist = try #require(plistValue as? [String: Any])
        let permittedIdentifiers = try #require(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/LogseqChatApp.swift"),
            encoding: .utf8
        )
        let mainSource = try String(
            contentsOf: root.appendingPathComponent("Darwin/Sources/Main.swift"),
            encoding: .utf8
        )

        #expect(permittedIdentifiers.contains("com.logseq.chat.refresh"))
        #expect(backgroundModes.contains("fetch"))
        #expect(appSource.contains("seconds: TimeInterval = 300"))
        #expect(mainSource.contains("LogseqChatBackgroundRefresh.register()"))
        #expect(mainSource.contains("LogseqChatBackgroundRefresh.schedule()"))
        #expect(mainSource.contains("case .active:"))
        #expect(mainSource.contains("AppDelegate.shared.onResume()"))
    }

    @Test func appDoesNotExposeDetailPages() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("#if SKIP"))
        #expect(!source.contains("detailBlock"))
        #expect(!source.contains(".sheet(item:"))
        #expect(source.contains("#else\n            NavigationStack"))
        #expect(!source.contains(".navigationDestination"))
        #expect(!source.contains("BlockDetailView"))
        #expect(!source.contains("EntityDetailView"))
        #expect(!source.contains("RelatedBlocksList"))
        #expect(!source.contains("DetailLine"))
    }

    @Test func composerSendKeepsEditingMode() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sendDraft = try #require(source.range(of: "private func sendDraft()"))
        let remainingSource = source[sendDraft.lowerBound...]
        let end = try #require(remainingSource.range(of: "\n    }\n}", options: []))
        let sendDraftSource = remainingSource[..<end.upperBound]

        #expect(sendDraftSource.contains("store.send(draft)"))
        #expect(sendDraftSource.contains("draft = \"\""))
        #expect(sendDraftSource.contains("composerExpanded = true"))
        #expect(sendDraftSource.contains("focusComposer()"))
        #expect(!sendDraftSource.contains("composerFocused = true"))
        #expect(!sendDraftSource.contains("composerExpanded = false"))
        #expect(!sendDraftSource.contains("composerFocused = false"))
    }

    @Test func composerDraftIsPersistedUntilSend() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sendDraft = try #require(source.range(of: "private func sendDraft()"))
        let remainingSource = source[sendDraft.lowerBound...]
        let end = try #require(remainingSource.range(of: "\n    }\n}", options: []))
        let sendDraftSource = remainingSource[..<end.upperBound]

        #expect(source.contains("@AppStorage(\"logseq.composerDraft\") private var draft = \"\""))
        #expect(!source.contains("@State private var draft = \"\""))
        #expect(sendDraftSource.contains("store.send(draft)"))
        #expect(sendDraftSource.contains("draft = \"\""))
    }

    @Test func chronologicalBlockListOnlyAutoScrollsAfterDataArrives() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("hasAutoScrolledInitially"))
        #expect(source.contains("autoScrollOnFirstAppear(proxy)"))
        #expect(!source.contains(".onChange(of: store.snapshot.revision)"))
        #expect(source.contains("guard !store.snapshot.blocks.isEmpty else { return }"))
        #expect(source.contains("newBlocks.count > oldBlocks.count"))
    }

    @Test func chronologicalBlockListScrollsToBottomForNewContentAndTopForSearch() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("scrollToBottom(proxy)"))
        #expect(source.contains("proxy.scrollTo(Self.blockListBottomID, anchor: .bottom)"))
        #expect(source.contains("if oldQuery.isEmpty && !newQuery.isEmpty"))
        #expect(source.contains("proxy.scrollTo(Self.blockListTopID, anchor: .top)"))
        #expect(!source.contains("scrollToRelevantContent"))
    }

    @Test func expandingComposerDoesNotReplaceTheSearchModifiedListTree() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let modifierStart = try #require(source.range(of: "@ViewBuilder public func platformSearchable("))
        let modifierSource = source[modifierStart.lowerBound...]
        let modifierEnd = try #require(modifierSource.range(of: "\n\n    @ViewBuilder public func platformRootNavigationChromeHidden"))
        let platformSearchable = modifierSource[..<modifierEnd.lowerBound]

        #expect(platformSearchable.contains("let presentation = Binding("))
        #expect(platformSearchable.contains("enabled && isPresented.wrappedValue"))
        #expect(!platformSearchable.contains("if enabled {"))
    }

    @Test func expandedComposerReservesScrollableSpaceAtTheBottom() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mainContentStart = try #require(source.range(of: "@ViewBuilder private var mainContent: some View"))
        let mainContentSource = source[mainContentStart.lowerBound...]
        let mainContentEnd = try #require(mainContentSource.range(of: "\n\n    private var stackedContent"))
        let mainContent = mainContentSource[..<mainContentEnd.lowerBound]

        #expect(mainContent.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(mainContent.contains("if shouldShowExpandedComposer"))
        #expect(!mainContent.contains("#else\n        stackedContent\n            .overlay(alignment: .bottom)"))
    }

    @Test func blockListKeepsContentClearOfFloatingChrome() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("private var blockListContentTopPadding: CGFloat"))
        #expect(source.contains(".frame(height: blockListContentTopPadding)"))
        #expect(source.contains("private var blockListContentBottomPadding: CGFloat"))
        #expect(source.contains("72.0"))
        #expect(!source.contains("132.0"))
        #expect(!source.contains(".padding(.top, 4)"))
        #expect(!source.contains(".padding(.bottom, 20)"))
    }

    @Test func headerUsesCompactTopSpacing() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("private var blockListContentTopPadding: CGFloat"))
        #expect(source.contains(".platformRootNavigationChromeHidden()"))
        #expect(source.contains("self.toolbarVisibility(.hidden, for: .navigationBar)"))
        #expect(source.contains("return searchExpanded ? 180.0 : 60.0"))
        #expect(source.contains("return 60.0"))
        #expect(!source.contains("return searchExpanded ? 96.0 : 60.0"))
        #expect(!source.contains("return searchExpanded ? 150.0 : 104.0"))
        #expect(!source.contains("return 104.0"))
    }

    @Test func searchUsesNativePresentationAndReplacesComposerOnIOS() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("@State private var searchPresented = false"))
        #expect(source.contains(".platformSearchable(\n                        enabled: !composerExpanded"))
        #expect(source.contains("self.searchable(\n            text: text,\n            isPresented: presentation"))
        #expect(source.contains(".platformSearchFocused($searchFocused)"))
        #expect(source.contains("self.searchFocused(binding)"))
        #expect(source.contains(".searchToolbarBehavior(.minimize)"))
        #expect(source.contains("private var shouldShowSearchToolbarItem: Bool"))
        #expect(source.contains("return !composerExpanded"))
        #expect(source.contains("showsSearch: shouldShowSearchToolbarItem"))
        #expect(source.contains("DefaultToolbarItem(kind: .search, placement: .bottomBar)"))
        #expect(source.contains("if shouldShowComposer"))
    }

    @Test func androidHasSearchAccessWhenComposerIsCollapsed() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let controlsRange = try #require(source.range(of: "private var androidFloatingControls: some View"))
        let controlsSource = source[controlsRange.lowerBound...]
        let nextView = try #require(controlsSource.range(of: "\n\n    private var floatingComposer"))
        let controls = controlsSource[..<nextView.lowerBound]

        #expect(source.contains(".overlay(alignment: .bottom) {\n                androidFloatingControls"))
        #expect(controls.contains("collapsedComposer"))
        #expect(controls.contains("IconImage(name: \"search\")"))
        #expect(controls.contains("expandSearch()"))
        #expect(controls.contains(".accessibilityIdentifier(\"button.search\")"))
        #expect(controls.contains("if shouldShowComposer && !composerExpanded"))
    }

    @Test func androidAttachmentControlUsesSystemDocumentPicker() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"), encoding: .utf8)
        let importer = try String(contentsOf: root.appendingPathComponent("Sources/LogseqChat/Skip/AndroidAssetImporter.kt"), encoding: .utf8)

        #expect(source.contains("AndroidAssetImporter.pick"))
        #expect(source.contains("store.addAsset("))
        #expect(importer.contains("OpenMultipleDocuments"))
        #expect(importer.contains("contentResolver.openInputStream"))
    }

    @Test func androidCoreCallsLeaveTheMainDispatcher() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChatModel/ViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("import kotlinx.coroutines.Dispatchers"))
        #expect(source.contains("import kotlinx.coroutines.withContext"))
        #expect(source.contains("withContext(Dispatchers.IO)"))
    }

    @Test func captureUsesBottomToolbarInsteadOfOverlayOnIOS() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains(".platformBottomComposerToolbar("))
        #expect(source.contains("showsComposer: shouldShowToolbarComposer"))
        #expect(source.contains("showsSearch: shouldShowSearchToolbarItem"))
        #expect(source.contains("private var shouldShowToolbarComposer: Bool"))
        #expect(source.contains("return shouldShowComposer && !composerExpanded"))
        #expect(source.contains("ToolbarItem(placement: .bottomBar)"))
        #expect(source.contains("ToolbarSpacer(.flexible, placement: .bottomBar)"))
        #expect(source.contains("DefaultToolbarItem(kind: .search, placement: .bottomBar)"))
        #expect(source.contains("showsComposer: Bool,\n        showsSearch: Bool"))
        #expect(source.contains("if showsSearch {\n                    ToolbarSpacer(.flexible, placement: .bottomBar)\n                    DefaultToolbarItem(kind: .search, placement: .bottomBar)\n                }"))
        #expect(!source.contains("if !isEditing {"))
        #expect(source.contains("bottomToolbarComposer"))
        #expect(source.contains("public func platformBottomComposerWidth() -> some View"))
        #expect(source.contains("UIScreen.main.bounds.width - 112.0"))
        let composerRange = try #require(source.range(of: "ToolbarItem(placement: .bottomBar)"))
        let searchRange = try #require(source.range(of: "DefaultToolbarItem(kind: .search, placement: .bottomBar)"))
        #expect(composerRange.lowerBound < searchRange.lowerBound)
        #expect(source.contains("#if SKIP\n        stackedContent"))
        #expect(source.contains(".overlay(alignment: .bottom) {\n                androidFloatingControls"))
        #expect(source.contains("#else\n        stackedContent\n            .safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(!source.contains("composerDismissLayer"))
        #expect(source.contains(".safeAreaInset(edge: .bottom, spacing: 0) {\n                if shouldShowExpandedComposer"))
        #expect(source.contains(".platformFloatingComposerInset()"))
    }

    @Test func macOSShowsCollapsedAndExpandedComposerOutsideTheIOSBottomToolbar() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("#elseif os(macOS)\n        stackedContent"))
        #expect(source.contains("if shouldShowComposer {\n                    floatingComposer"))
        #expect(source.contains(".platformIconMenuStyle()"))
        #expect(source.contains("public func platformIconMenuStyle() -> some View"))
        #expect(source.contains("self.menuStyle(.borderlessButton)\n            .menuIndicator(.hidden)"))
        #expect(source.contains("private static let assetBundle: Bundle"))
        #expect(source.contains("Bundle.main.resourceURL?\n                .appendingPathComponent(\"logseq-chat_LogseqChat.bundle\")"))
        #expect(source.contains("Image(name, bundle: Self.assetBundle)"))
    }

    @Test func expandedCaptureUsesFloatingComposerOutsideToolbarOnIOS() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let toolbarComposerRange = try #require(source.range(of: "private var bottomToolbarComposer: some View"))
        let toolbarComposerSource = source[toolbarComposerRange.lowerBound...]
        let nextFunction = try #require(toolbarComposerSource.range(of: "\n    #endif\n\n    #if SKIP"))
        let bottomToolbarComposer = toolbarComposerSource[..<nextFunction.lowerBound]
        let expandedRange = try #require(source.range(of: "private var expandedComposer: some View"))
        let expandedSource = source[expandedRange.lowerBound...]
        let nextView = try #require(expandedSource.range(of: "\n\n    private var collapsedComposer: some View"))
        let expandedComposer = expandedSource[..<nextView.lowerBound]

        #expect(source.contains("bottomToolbarComposer\n                            .platformBottomComposerWidth()"))
        #expect(source.contains("private var floatingComposer: some View"))
        #expect(source.contains("if shouldShowExpandedComposer {\n                    floatingComposer"))
        #expect(bottomToolbarComposer.contains("toolbarCollapsedComposer"))
        #expect(!bottomToolbarComposer.contains("toolbarExpandedComposer"))
        #expect(!source.contains("private var toolbarExpandedComposer: some View"))
        #expect(!bottomToolbarComposer.contains(".platformGlassContainer()"))
        #expect(!bottomToolbarComposer.contains(".padding(.horizontal, 16)"))
        #expect(expandedComposer.contains("TextField(\"Capture\""))
        #expect(expandedComposer.contains("IconImage(name: \"arrow_upward\")"))
        #expect(!expandedComposer.contains(".platformGlassProminentButtonStyle()"))
    }

    @Test func expandedCaptureCanRefocusAfterDeletingDraft() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let expandedRange = try #require(source.range(of: "private var expandedComposer: some View"))
        let expandedSource = source[expandedRange.lowerBound...]
        let nextView = try #require(expandedSource.range(of: "\n\n    private var collapsedComposer: some View"))
        let expandedComposer = expandedSource[..<nextView.lowerBound]

        #expect(expandedComposer.contains(".onTapGesture {\n            focusComposer()\n        }"))
        #expect(expandedComposer.contains(".onChange(of: draft)"))
        #expect(expandedComposer.contains("if composerExpanded && value.isEmpty {\n                focusComposer()\n            }"))
    }

    @Test func androidComposerExpandsAndFocusesWithoutArtificialDelay() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let expandStart = try #require(source.range(of: "private func expandComposer()"))
        let focusEnd = try #require(source.range(of: "\n    private func focusSearch()", range: expandStart.lowerBound..<source.endIndex))
        let composerFocusSource = source[expandStart.lowerBound..<focusEnd.lowerBound]

        #expect(composerFocusSource.contains("#if SKIP\n        composerExpanded = true\n        #else"))
        #expect(composerFocusSource.contains("#if SKIP\n        DispatchQueue.main.async {\n            composerFocused = true\n        }\n        #else"))
        #expect(!composerFocusSource.contains("#if SKIP\n        withAnimation"))
        #expect(!composerFocusSource.contains("#if SKIP\n        DispatchQueue.main.asyncAfter"))
    }

    @Test func onlyFailedBlocksShowStatusIndicator() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let blockRowRange = try #require(source.range(of: "private struct BlockRow: View"))
        let blockRowSource = source[blockRowRange.lowerBound...]
        let nextView = try #require(blockRowSource.range(of: "\n\nprivate struct IconImage: View"))
        let blockRow = blockRowSource[..<nextView.lowerBound]

        #expect(blockRow.contains("if block.isFailedSync"))
        #expect(blockRow.contains("ProgressView()"))
        #expect(blockRow.contains(".accessibilityLabel(\"Sync failed\")"))
        #expect(!blockRow.contains("isPendingSync ?"))
        #expect(!blockRow.contains("check_circle"))
        #expect(!blockRow.contains("upload"))
        #expect(!blockRow.contains("Synced"))
        #expect(!blockRow.contains("Pending upload"))
    }

    @Test func expandedComposerUsesEditorOverSendToolbar() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let expandedRange = try #require(source.range(of: "private var expandedComposer: some View"))
        let expandedSource = source[expandedRange.lowerBound...]
        let nextView = try #require(expandedSource.range(of: "\n\n    private var collapsedComposer: some View"))
        let expandedComposer = expandedSource[..<nextView.lowerBound]

        #expect(expandedComposer.contains("VStack(alignment: .leading, spacing: 8)"))
        #expect(expandedComposer.contains("TextField(\"Capture\""))
        #expect(expandedComposer.contains("accessibilityIdentifier(\"button.attachment\")"))
        #expect(expandedComposer.contains("accessibilityIdentifier(\"button.task-status\")"))
        #expect(expandedComposer.contains("IconImage(name: \"arrow_upward\")"))
        #expect(expandedComposer.contains("size: 22"))
        #expect(expandedComposer.contains(".frame(width: 22, height: 22)"))
        #expect(expandedComposer.contains(".frame(width: 32, height: 32)"))
        #expect(expandedComposer.contains(".frame(width: 40, height: 40)"))
        #expect(expandedComposer.contains(".background(Circle().fill(Color.black))"))
        #expect(!expandedComposer.contains(".platformGlassProminentButtonStyle()"))
        #expect(!expandedComposer.contains(".frame(width: 28, height: 28)"))
        #expect(!expandedComposer.contains(".frame(width: 30, height: 28)"))
        #expect(!expandedComposer.contains("HStack(alignment: .bottom, spacing: 10)"))
        #expect(expandedComposer.contains("HStack(alignment: .center, spacing: 8)"))
        #expect(expandedComposer.contains(".platformGlassContainer(cornerRadius: 10)"))
        #expect(expandedComposer.contains(".platformRoundedHitTarget(cornerRadius: 10)"))
    }

    @Test func attachmentMenuUsesDistinctPhotoCameraAndFileActions() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let infoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Darwin/Info.plist")
        let info = try String(contentsOf: infoURL, encoding: .utf8)

        let nativeStart = try #require(source.range(of: "// Bottom-anchored iOS menus"))
        let nativeBranch = source[nativeStart.lowerBound...]
        let file = try #require(nativeBranch.range(of: "Text(\"File\")"))
        let camera = try #require(nativeBranch.range(of: "Text(\"Camera\")"))
        let photo = try #require(nativeBranch.range(of: "Text(\"Photo\")"))
        #expect(file.lowerBound < camera.lowerBound)
        #expect(camera.lowerBound < photo.lowerBound)
        #expect(source.contains("photoPickerPresented = true"))
        #expect(source.contains(".photosPicker("))
        #expect(source.contains("cameraPresented = true"))
        #expect(source.contains("fileImporterPresented = true"))
        #expect(info.contains("NSCameraUsageDescription"))
    }

    @Test func taskStatusMenuIncludesEveryLogseqBuiltInStatus() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ForEach(taskStatusMenuStatuses)"))
        #expect(source.contains("Array(availableTaskStatuses.reversed())"))
        for iconName in ["task_backlog", "task_todo", "task_doing", "task_review", "task_done", "task_canceled"] {
            #expect(source.contains("\"\(iconName)\""))
        }
    }

    @Test func localAssetsUseNativeInlinePreviewAndSystemOpen() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("Image(uiImage:"))
        #expect(source.contains("VideoPlayer(player:"))
        #expect(source.contains(".quickLookPreview($previewAssetURL)"))
        #expect(source.contains("private struct AssetPreview"))
    }

    @Test func imageAssetPreviewDoesNotRenderItsTitle() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let imageStart = try #require(source.range(of: "if let path = block.localPath, isImage"))
        let imageBranch = source[imageStart.lowerBound...]
        let audioStart = try #require(imageBranch.range(of: "} else if let path = block.localPath, isAudio"))
        let imageSource = imageBranch[..<audioStart.lowerBound]

        #expect(imageSource.contains("Image(uiImage: image)"))
        #expect(!imageSource.contains("assetTitle"))
    }

    @Test func composerGlassUsesTheRequestedCornerRadiusInsteadOfDefaultCapsule() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let helperRange = try #require(source.range(of: "public func platformGlassContainer(cornerRadius: CGFloat = 28)"))
        let helperSource = source[helperRange.lowerBound...]
        let nextHelper = try #require(helperSource.range(of: "\n\n    @ViewBuilder public func platformGlassCapsule"))
        let glassContainer = helperSource[..<nextHelper.lowerBound]

        #expect(glassContainer.contains(".glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))"))
        #expect(!glassContainer.contains("self.glassEffect()\n                .clipShape"))
    }

    @Test func blockListDoesNotCompeteWithBlockTapHandling() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let blockListRange = try #require(source.range(of: "private var blockList: some View"))
        let blockListSource = source[blockListRange.lowerBound...]
        let nextView = try #require(blockListSource.range(of: "\n\n    private func autoScrollOnFirstAppear"))
        let blockList = blockListSource[..<nextView.lowerBound]

        #expect(!blockList.contains(".onTapGesture"))
        #expect(blockList.contains("handleBlockTap(block)"))
    }

    @Test func journalBlocksRemainDirectLazyStackChildren() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sectionsStart = try #require(source.range(of: "ForEach(store.sections) { section in"))
        let sectionsSource = source[sectionsStart.lowerBound...]
        let listEnd = try #require(sectionsSource.range(of: "\n                    Color.clear"))
        let sectionRows = sectionsSource[..<listEnd.lowerBound]

        #expect(sectionRows.contains("ForEach(section.blocks) { block in"))
        #expect(!sectionRows.contains("VStack(alignment: .leading"))
    }

    @Test func tappingBlockDismissesAnOpenComposerOtherwiseLoadsTheBlock() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let blockListRange = try #require(source.range(of: "private var blockList: some View"))
        let blockListSource = source[blockListRange.lowerBound...]
        let nextView = try #require(blockListSource.range(of: "\n\n    private var blockListContentTopPadding"))
        let blockList = blockListSource[..<nextView.lowerBound]

        #expect(blockList.contains("handleBlockTap(block)"))
        #expect(!blockList.contains("NavigationLink(value: block)"))
        #expect(!blockList.contains("openBlock(block)"))
        #expect(source.contains("private func handleBlockTap(_ block: LogseqBlock)"))
        #expect(source.contains("guard !composerExpanded else {\n            dismissComposerEditing()\n            return\n        }"))
        #expect(source.contains("private func editBlock(_ block: LogseqBlock)"))
        #expect(source.contains("editingBlock = block"))
        #expect(source.contains("draft = block.title"))
        #expect(source.contains("selectedTaskStatus = block.status"))
        #expect(source.contains("store.update(block: editingBlock, title: draft, status: selectedTaskStatus)"))
    }

    @Test func dismissingComposerClearsDraftTaskStatusAndEditTarget() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let dismissStart = try #require(source.range(of: "private func dismissComposerEditing()"))
        let remainingSource = source[dismissStart.lowerBound...]
        let dismissEnd = try #require(remainingSource.range(of: "\n    }\n\n    private func sendDraft()"))
        let dismissSource = remainingSource[..<dismissEnd.upperBound]

        #expect(!dismissSource.contains("if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        #expect(dismissSource.contains("draft = \"\""))
        #expect(dismissSource.contains("selectedTaskStatus = nil"))
        #expect(dismissSource.contains("editingBlock = nil"))
    }

    @Test func taskStatusCanBePickedDirectlyFromTaskBlock() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rowStart = try #require(source.range(of: "private struct BlockRow: View"))
        let remainingSource = source[rowStart.lowerBound...]
        let rowEnd = try #require(remainingSource.range(of: "\n\nprivate struct AssetPreview: View"))
        let rowSource = remainingSource[..<rowEnd.lowerBound]

        #expect(rowSource.contains("Menu"))
        #expect(rowSource.contains("onStatusChange"))
        #expect(rowSource.contains("TaskStatusIcon(status: status)"))
        #expect(source.contains("store.updateStatus(block: block, status: status)"))
    }

    @Test func expandedComposerDoesNotOverlayAFullScreenGestureLayer() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("composerDismissLayer"))
        #expect(source.contains("private var blockList: some View"))
        #expect(source.contains("private func handleBlockTap(_ block: LogseqBlock)"))
        #expect(source.contains("dismissComposerEditing()"))
    }

    @Test func iosE2EUsesNativeSearchToolbarControl() throws {
        let flowURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".maestro/ios-capture-responsive.yaml")
        let flow = try String(contentsOf: flowURL, encoding: .utf8)

        #expect(!flow.contains("button.search"))
        #expect(flow.contains("tapOn: \"Search\""))
        #expect(flow.contains("tapOn: \"close\""))
        #expect(!flow.contains("tapOn: \"Cancel\""))
        #expect(!flow.contains("field.pat"))
        #expect(flow.contains("text: \"Enter your username\""))
        #expect(flow.contains("text: \"Enter your password\""))
        #expect(flow.contains("text: \"Sign In\""))
        #expect(flow.contains("index: 1"))
        #expect(!flow.contains("field.email"))
        #expect(!flow.contains("field.password"))
        #expect(flow.contains("eraseText: 8"))
        #expect(flow.contains("inputText: \"After clear\""))
        let sendButton = try #require(flow.range(of: "id: \"button.send\""))
        let flowAfterSend = flow[sendButton.upperBound...]
        #expect(!flowAfterSend.contains("tapOn: \"Search\""))
    }

    @Test func iosE2EScriptClearsPersistedConnectionStateBeforeInstall() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/test-ios-e2e.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let uninstallRange = try #require(script.range(of: "xcrun simctl uninstall"))
        let installRange = try #require(script.range(of: "xcrun simctl install"))
        let resetSource = script[uninstallRange.lowerBound..<installRange.lowerBound]

        #expect(resetSource.contains("defaults delete \"$app_id\" logseq.baseURL"))
        #expect(resetSource.contains("defaults delete \"$app_id\" logseq.composerDraft"))
        #expect(!script.contains("LOGSEQ_CHAT_E2E_PAT"))
        #expect(script.contains("LOGSEQ_CHAT_E2E_USERNAME"))
        #expect(script.contains("LOGSEQ_CHAT_E2E_PASSWORD"))
    }

    @Test func iosBuildUsesStaticAmplifyProductsWithoutLegacyCognitoFrameworks() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let device = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-device.sh"),
            encoding: .utf8
        )
        let simulator = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-simulator.sh"),
            encoding: .utf8
        )

        for script in [device, simulator] {
            #expect(!script.contains("AWSCore.framework"))
            #expect(!script.contains("AWSCognitoIdentityProvider.framework"))
            #expect(!script.contains("AWSCognitoIdentityProviderASF.framework"))
            #expect(!script.contains("cognito_frameworks"))
            #expect(script.contains("*.bundle"))
        }
    }

    @Test func iosNativeObjectsOnlyLinkIntoTheAppTarget() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let device = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-device.sh"),
            encoding: .utf8
        )

        #expect(package.contains("LOGSEQ_CHAT_NATIVE_LINK_INPUTS"))
        #expect(package.contains("linkerSettings: logseqChatLinkerSettings"))
        #expect(device.contains("LOGSEQ_CHAT_NATIVE_LINK_INPUTS="))
        #expect(!device.contains("-Xlinker \"$core_object\""))
        #expect(!device.contains("-Xlinker \"$ffi_object\""))
    }

    @Test func iosNativeCoreFlagIsDefinedForTheModelTargetThatCallsIt() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let modelTargetStart = try #require(package.range(of: ".target(name: \"LogseqChatModel\""))
        let modelTargetAndFollowing = package[modelTargetStart.lowerBound...]
        let coreTargetStart = try #require(
            modelTargetAndFollowing.range(of: "\n        .target(\n            name: \"LogseqChatCoreABI\"")
        )
        let modelTarget = modelTargetAndFollowing[..<coreTargetStart.lowerBound]

        #expect(modelTarget.contains(".define(\"LOGSEQ_CHAT_CORE\", .when(platforms: [.iOS]))"))
    }

    @Test func iosSimulatorBuildUsesTheSameSyncCoreAsDevice() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let simulator = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-simulator.sh"),
            encoding: .utf8
        )

        for module in [
            "logseq_chat_edn",
            "logseq_chat_sync_protocol",
            "logseq_chat_sync_state",
            "logseq_chat_sync_checkpoint",
            "logseq_chat_snapshot",
            "logseq_chat_entity_sync",
            "logseq_chat_graph_read",
            "logseq_chat_sse",
            "logseq_chat_logseq_storage_codec",
            "logseq_chat_graph_store",
            "logseq_chat_sync_session"
        ] {
            #expect(simulator.contains("\(module).cmx"))
        }
        #expect(simulator.contains("logseq_chat_graph_store_stubs.c"))
        #expect(simulator.contains("$graph_store_object"))
    }

    @Test func iosSimulatorRelinksWhenTheNativeCoreChanges() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build-mobile-ios-simulator.sh")
        let simulator = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(simulator.contains("native_link_fingerprint="))
        #expect(simulator.contains("native-link-inputs/$native_link_fingerprint"))
        #expect(simulator.contains("LOGSEQ_CHAT_NATIVE_LINK_INPUTS=\"$fingerprinted_native_link_inputs\""))
    }

    @Test func iosSimulatorEmbedsKeychainEntitlementsAtLinkTime() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let simulator = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-simulator.sh"),
            encoding: .utf8
        )

        #expect(package.contains("LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS"))
        #expect(package.contains("\"__TEXT\", \"-Xlinker\", \"__entitlements\""))
        #expect(simulator.contains("application-identifier"))
        #expect(simulator.contains("keychain-access-groups"))
        #expect(simulator.contains("LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS=\"$simulator_entitlements\""))
        #expect(simulator.contains("codesign --force --sign - --entitlements \"$signature_entitlements\""))
        #expect(simulator.contains("--generate-entitlement-der"))
    }

    @Test func clientWritesUseSemanticRESTWithoutTxBatch() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let api = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_api.ml"),
            encoding: .utf8
        )
        let rpc = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_rpc.ml"),
            encoding: .utf8
        )

        #expect(api.contains("/api/v1/graphs/%s/capture"))
        #expect(api.contains("/api/v1/graphs/%s/blocks/%s"))
        #expect(!api.contains("/chat/tx/batch"))
        #expect(!rpc.contains("chat_tx_batch_request"))
    }

    @Test func headerFallsBackToTheCachedGraphIdentity() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )

        #expect(content.contains("store.snapshot.selectedGraphId ?? selectedGraphID"))
        #expect(!content.contains("return \"Not connected\""))
    }

    @Test func cachedGraphOpensBeforeAuthenticationRestore() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let localRestore = try #require(content.range(of: "await restoreCachedGraphIfAvailable()"))
        let authRestore = try #require(content.range(of: "await authentication.restore()"))

        #expect(localRestore.lowerBound < authRestore.lowerBound)
    }

    @Test func cachedGraphDoesNotStartNetworkSyncWhileAuthenticationIsRestoring() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/ContentView.swift"),
            encoding: .utf8
        )
        let handlerStart = try #require(
            content.range(of: ".onChange(of: store.snapshot.selectedGraphId)")
        )
        let following = content[handlerStart.lowerBound...]
        let handlerEnd = try #require(following.range(of: "\n        .sheet("))
        let handler = following[..<handlerEnd.lowerBound]

        #expect(handler.contains("guard authentication.state == .signedIn else { return }"))
    }

    @Test func nativeHTTPReleasesTheOCamlRuntimeWhileOfflineRequestsWait() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let transport = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_https_darwin.m"),
            encoding: .utf8
        )
        let ffi = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_core_ffi.c"),
            encoding: .utf8
        )

        #expect(transport.contains("caml_enter_blocking_section();"))
        #expect(transport.contains("caml_leave_blocking_section();"))
        #expect(!ffi.contains("pthread_mutex_lock(&logseq_chat_call_mutex)"))
    }

    @Test func blockEditsQueueLocallyBeforeAnyRESTRequest() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let rpc = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_rpc.ml"),
            encoding: .utf8
        )
        let updateStart = try #require(rpc.range(of: "| \"updateBlockStatus\" ->"))
        let following = rpc[updateStart.lowerBound...]
        let updateEnd = try #require(following.range(of: "\n  | \"select\" ->"))
        let updateHandlers = following[..<updateEnd.lowerBound]

        #expect(!updateHandlers.contains("Http.send"))
        #expect(!updateHandlers.contains("save_remote_block"))
        #expect(rpc.contains("save_remote_block session config block"))
        #expect(rpc.contains("if session.sync_in_progress"))
    }

    @Test func iosShellBuildUsesSwiftPMDependencyGraph() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let device = try String(
            contentsOf: root.appendingPathComponent("scripts/build-mobile-ios-device.sh"),
            encoding: .utf8
        )

        #expect(package.contains(".executable(name: \"LogseqChatShell\""))
        #expect(package.contains(".executableTarget("))
        #expect(package.contains("path: \"Darwin/Sources\""))
        #expect(device.contains("--product LogseqChatShell"))
        #expect(device.contains("cp \"$swift_build_dir/LogseqChatShell\" \"$app_dir/LogseqChat\""))
        #expect(!device.contains("xcrun --sdk iphoneos swiftc"))
    }

    @Test func iosPackagingRecreatesTheGeneratedAppBundle() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for name in ["build-mobile-ios-device.sh", "build-mobile-ios-simulator.sh"] {
            let script = try String(
                contentsOf: root.appendingPathComponent("scripts/\(name)"),
                encoding: .utf8
            )
            let remove = try #require(script.range(of: "rm -rf \"$app_dir\""))
            let copy = try #require(script.range(of: "cp \"$repo_root/Darwin/Info.plist\""))
            #expect(remove.lowerBound < copy.lowerBound)
        }
    }

    @Test func appleRuntimeInitializesOCamlOnThePersistentCoreThread() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChat/LogseqChatApp.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChatModel/ViewModel.swift"),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent("core/logseq_chat_core_ffi.h"),
            encoding: .utf8
        )
        let abiHeader = try String(
            contentsOf: root.appendingPathComponent("Sources/LogseqChatCoreABI/include/LogseqChatCoreABI.h"),
            encoding: .utf8
        )
        #expect(!app.contains("LogseqChatCore.shared.initialize()"))
        #expect(model.contains("private final class LogseqChatCoreExecutor"))
        #expect(model.contains("Thread {"))
        let executor = try #require(model.range(of: "private final class LogseqChatCoreExecutor"))
        let remainingExecutor = model[executor.lowerBound...]
        let initialize = try #require(remainingExecutor.range(of: "LogseqChatCore.shared.initialize()"))
        let callCore = try #require(remainingExecutor.range(of: "callCore(requestJSON)"))
        #expect(initialize.lowerBound < callCore.lowerBound)
        #expect(model.contains("public func initialize()"))
        #expect(model.contains("LogseqChatCoreABI.logseq_chat_initialize()"))
        #expect(header.contains("void logseq_chat_initialize(void);"))
        #expect(abiHeader.contains("void logseq_chat_initialize(void);"))
    }

    @Test func composerDismissesWhenLeavingHomeOrEnteringSearch() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LogseqChat/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let dismissComposer = try #require(source.range(of: "private func dismissComposerEditing()"))
        let remainingSource = source[dismissComposer.lowerBound...]
        let end = try #require(remainingSource.range(of: "\n    }\n\n    private func sendDraft()", options: []))
        let dismissComposerSource = remainingSource[..<end.upperBound]

        #expect(source.contains("private func editBlock(_ block: LogseqBlock)"))
        #expect(source.contains("guard !presented else {\n            dismissComposerEditing()"))
        #expect(dismissComposerSource.contains("composerExpanded = false"))
        #expect(dismissComposerSource.contains("composerFocused = false"))
    }

    #endif

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
