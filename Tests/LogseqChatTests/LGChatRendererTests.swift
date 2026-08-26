import Foundation
import Testing
@testable import LogseqChat
import LogseqChatModel
import LUIAppleBackend

@MainActor
@Suite("LG chat renderer")
struct LGChatRendererTests {
    @Test("applies retained patches and exposes the stable runtime root")
    func appliesRetainedPatches() throws {
        let renderer = LGChatRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-node","id":2,"kind":"text"},
          {"op":"set-prop","id":2,"property":"text","value":"Before"},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)

        try renderer.apply(patchJSON: """
        {"generation":2,"ops":[
          {"op":"set-prop","id":2,"property":"text","value":"After"}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }

    @Test("registers the native rich block renderer with the LG fingerprint")
    func registersRichBlockRenderer() throws {
        let renderer = LGChatRenderer()

        try renderer.apply(patchJSON: """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"},
          {"op":"create-extension","id":2,"identifier":"outliner-block-content","fingerprint":"lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:11:markup-json:string:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none|events:9:open-node[4:uuid:string:required]"},
          {"op":"set-extension-prop","id":2,"property":"title","value":"Project"},
          {"op":"set-extension-prop","id":2,"property":"markup-json","value":"[]"},
          {"op":"set-extension-prop","id":2,"property":"youtube-target-url","value":""},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """)

        #expect(renderer.rootID == 1)
    }

    @Test("forwards renderer events without owning application state")
    func forwardsEvents() {
        let renderer = LGChatRenderer()
        var received: LGChatRendererEvent?
        renderer.onEvent = { received = $0 }

        renderer.receiveForTesting(
            LGChatRendererEvent(kind: LGChatRendererEventKind.press, nodeID: 42)
        )

        #expect(received == LGChatRendererEvent(
            kind: LGChatRendererEventKind.press,
            nodeID: 42
        ))
    }

    @Test("routes renderer events through the LG native runtime")
    func routesEventsThroughNativeRuntime() throws {
        let native = LGChatNativeRuntimeProbe()
        let runtime = LGChatRuntime(native: native)

        try runtime.start(platformCode: 2)
        #expect(runtime.renderer.rootID == 1)

        runtime.renderer.receiveForTesting(
            LGChatRendererEvent(kind: .press, nodeID: 7)
        )

        #expect(native.startedPlatforms == [2])
        #expect(native.pressedNodes == [7])
        #expect(runtime.renderer.rootID == 1)
    }

    @Test("routes native extension events through one LG bridge")
    func routesNativeExtensionEvents() throws {
        let native = LGChatNativeRuntimeProbe()
        let runtime = LGChatRuntime(native: native)
        try runtime.start(platformCode: 2)

        runtime.renderer.receiveForTesting(
            LGChatRendererEvent(
                kind: .extension,
                nodeID: 17,
                extensionIdentifier: "outliner-editor",
                extensionName: "text-change",
                extensionValues: [
                    "title": LUIExtensionValue.string("Updated"),
                    "caret-utf16-offset": LUIExtensionValue.int(7),
                ]
            )
        )
        runtime.renderer.receiveForTesting(
            LGChatRendererEvent(
                kind: .extension,
                nodeID: 18,
                extensionIdentifier: "outliner-block-content",
                extensionName: "open-node",
                extensionValues: ["uuid": LUIExtensionValue.string("page-a")]
            )
        )

        #expect(native.extensionEvents == [
            LGChatExtensionEventProbe(
                node: 17,
                identifier: "outliner-editor",
                name: "text-change",
                text: "Updated",
                value: 7
            ),
            LGChatExtensionEventProbe(
                node: 18,
                identifier: "outliner-block-content",
                name: "open-node",
                text: "page-a",
                value: 0
            ),
        ])
        #expect(runtime.lastError == nil)
    }

    @Test("executes and resolves typed LG effects")
    func executesTypedEffects() async {
        let native = LGChatNativeRuntimeProbe()
        native.effects = [
            "{\"id\":7,\"kind\":\"send-capture\",\"text\":\"Project note\"}"
        ]
        let executor = LGChatEffectExecutorProbe()
        let runtime = LGChatRuntime(native: native, effectExecutor: executor)

        await runtime.drainEffectsForTesting()

        #expect(executor.effects == [
            LGChatEffect(id: 7, kind: "send-capture", text: "Project note")
        ])
        #expect(native.resolutions == [
            LGChatEffectResolutionProbe(id: 7, succeeded: true, message: "core response")
        ])
        #expect(native.appliedSnapshots == ["core response"])
        #expect(native.effects.isEmpty)
        #expect(runtime.lastError == nil)
    }

    @Test("applies a launch snapshot that arrives before the renderer starts")
    func queuesLaunchSnapshotUntilStart() throws {
        let native = LGChatNativeRuntimeProbe()
        let runtime = LGChatRuntime(native: native)

        try runtime.applyCoreResponse("launch response")
        #expect(native.appliedSnapshots.isEmpty)

        try runtime.start(platformCode: 2)

        #expect(native.startedPlatforms == [2])
        #expect(native.appliedSnapshots == ["launch response"])
        #expect(runtime.isStarted)
    }

    @Test("search effects dispatch the existing core search action")
    func searchEffectsUseCoreSearch() async throws {
        var capturedRequest: LogseqChatRPCRequest?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequest = request
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(id: 9, kind: "search-nodes", text: "project alpha")
        )
        let request = try #require(capturedRequest)

        #expect(request.params.action == "searchNodes")
        #expect(request.params.payload == "project alpha")
        #expect(resolution.succeeded)
    }

    @Test("outliner tap effects dispatch the existing core reducer action")
    func outlinerTapEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequest: LogseqChatRPCRequest?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequest = request
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(id: 10, kind: "tap-outliner-block", text: "block-a")
        )
        let request = try #require(capturedRequest)

        #expect(request.params.action == "outlinerEvent")
        #expect(request.params.payload?.contains("tapBlock") == true)
        #expect(request.params.payload?.contains("block-a") == true)
        #expect(resolution.succeeded)
    }

    @Test("outliner structure effects reuse the existing core reducer")
    func outlinerStructureEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let collapse = await executor.execute(
            LGChatEffect(id: 11, kind: "toggle-outliner-collapsed", text: "parent")
        )
        let zoom = await executor.execute(
            LGChatEffect(id: 12, kind: "zoom-outliner-block", text: "parent")
        )

        #expect(capturedRequests.count == 2)
        #expect(capturedRequests[0].params.action == "outlinerEvent")
        #expect(capturedRequests[0].params.payload?.contains("toggleCollapsed") == true)
        #expect(capturedRequests[1].params.action == "outlinerEvent")
        #expect(capturedRequests[1].params.payload?.contains("zoomIn") == true)
        #expect(collapse.succeeded)
        #expect(zoom.succeeded)
    }

    @Test("add-first-block effects reuse the existing core reducer")
    func addFirstBlockEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequest: LogseqChatRPCRequest?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequest = request
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(id: 13, kind: "add-root-block", text: "page-a")
        )
        let request = try #require(capturedRequest)

        #expect(request.params.action == "outlinerEvent")
        #expect(request.params.payload?.contains("addRootBlock") == true)
        #expect(request.params.payload?.contains("page-a") == true)
        #expect(resolution.succeeded)
    }

    @Test("node navigation effects dispatch the existing core actions")
    func nodeNavigationEffectsUseCoreNavigation() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let open = await executor.execute(
            LGChatEffect(id: 20, kind: "open-node", text: "node-a")
        )
        let close = await executor.execute(
            LGChatEffect(id: 21, kind: "close-node", text: "node-a")
        )

        #expect(capturedRequests.map(\.params.action) == ["openNode", "closeNode"])
        #expect(capturedRequests[0].params.payload?.contains("node-a") == true)
        #expect(capturedRequests[1].params.payload == nil)
        #expect(open.succeeded)
        #expect(close.succeeded)
    }

    @Test("sidebar navigation effects dispatch the existing core actions")
    func sidebarNavigationEffectsUseCoreNavigation() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let select = await executor.execute(
            LGChatEffect(id: 22, kind: "select-sidebar-page", text: "page-a")
        )
        let clear = await executor.execute(
            LGChatEffect(id: 23, kind: "clear-selected-page", text: "")
        )

        #expect(capturedRequests.map(\.params.action) == ["selectPage", "clearSelectedPage"])
        #expect(capturedRequests[0].params.payload == "page-a")
        #expect(capturedRequests[1].params.payload == nil)
        #expect(select.succeeded)
        #expect(clear.succeeded)
    }

    @Test("flashcard effects preserve review identity, rating, time, and operation id")
    func flashcardEffectsUseCoreFlashcards() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let load = await executor.execute(
            LGChatEffect(id: 24, kind: "load-flashcards", text: "")
        )
        let review = await executor.execute(
            LGChatEffect(
                id: 25,
                kind: "review-flashcard",
                text: "good",
                uuid: "card-a"
            )
        )

        #expect(capturedRequests.map(\.params.action) == ["loadFlashcards", "reviewFlashcard"])
        let loadPayload = try #require(capturedRequests[0].params.payload)
        let loadTime = try #require(Int64(loadPayload))
        #expect(loadTime > 0)
        let reviewPayload = try #require(capturedRequests[1].params.payload)
        let reviewData = Data(reviewPayload.utf8)
        let payload = try JSONDecoder().decode(FlashcardReviewPayload.self, from: reviewData)
        #expect(payload.uuid == "card-a")
        #expect(payload.rating == "good")
        #expect(payload.now > 0)
        #expect(!payload.operationId.isEmpty)
        #expect(load.succeeded)
        #expect(review.succeeded)
    }

    @Test("flashcard review rejects effects without a card UUID")
    func flashcardReviewRequiresUUID() async {
        var callCount = 0
        let executor = LGChatCoreEffectExecutor { _ in
            callCount += 1
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(id: 26, kind: "review-flashcard", text: "again")
        )

        #expect(!resolution.succeeded)
        #expect(resolution.message.contains("UUID"))
        #expect(callCount == 0)
    }

    @Test("graph catalog effects reuse the existing core graph lifecycle")
    func graphEffectsUseCoreLifecycle() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        var deletedGraphID: String?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let refresh = await executor.execute(
            LGChatEffect(id: 27, kind: "refresh-graphs", text: "")
        )
        let open = await executor.execute(
            LGChatEffect(id: 28, kind: "open-graph", text: "graph-a")
        )
        let create = await executor.execute(
            LGChatEffect(id: 29, kind: "create-graph", text: "New graph", value: 1)
        )
        let platformExecutor = LGChatCoreEffectExecutor(
            deleteLocalGraph: { graphID in
                deletedGraphID = graphID
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            },
            callCore: { _ in
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            }
        )
        let delete = await platformExecutor.execute(
            LGChatEffect(id: 30, kind: "delete-local-graph", text: "graph-a")
        )

        #expect(capturedRequests.map(\.params.action) == [
            "refresh", "selectGraph", "createSyncGraph",
        ])
        #expect(capturedRequests[1].params.payload == "graph-a")
        let createPayload = try #require(capturedRequests[2].params.payload)
        #expect(createPayload.contains("New graph"))
        #expect(createPayload.contains("isEncrypted"))
        #expect(createPayload.contains("true"))
        #expect(deletedGraphID == "graph-a")
        #expect(refresh.succeeded)
        #expect(open.succeeded)
        #expect(create.succeeded)
        #expect(delete.succeeded)
    }

    @Test("settings and diagnostics effects stay on the platform boundary")
    func settingsEffectsUsePlatformBoundary() async {
        var platformKinds: [String] = []
        var coreCallCount = 0
        let executor = LGChatCoreEffectExecutor(
            platformEffect: { effect in
                platformKinds.append(effect.kind)
                return LGChatEffectResolution(succeeded: true, message: "ok")
            },
            callCore: { _ in
                coreCallCount += 1
                return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
            }
        )

        let effects = [
            LGChatEffect(id: 31, kind: "save-settings", text: "{}"),
            LGChatEffect(id: 32, kind: "refresh-runtime-log", text: "ui", value: 3),
            LGChatEffect(id: 33, kind: "copy-runtime-log", text: "[]"),
            LGChatEffect(id: 34, kind: "sign-out", text: ""),
        ]
        for effect in effects {
            #expect((await executor.execute(effect)).succeeded)
        }

        #expect(platformKinds == effects.map(\.kind))
        #expect(coreCallCount == 0)
    }

    @Test("outliner selection effects reuse the existing core reducer")
    func outlinerSelectionEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequests: [LogseqChatRPCRequest] = []
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequests.append(request)
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let longPress = await executor.execute(
            LGChatEffect(id: 13, kind: "long-press-outliner-block", text: "parent")
        )
        let copy = await executor.execute(
            LGChatEffect(id: 14, kind: "outliner-toolbar", text: "copy")
        )

        #expect(capturedRequests.count == 2)
        #expect(capturedRequests[0].params.payload?.contains("longPressBlock") == true)
        #expect(capturedRequests[0].params.payload?.contains("parent") == true)
        #expect(capturedRequests[1].params.payload?.contains("toolbar") == true)
        #expect(capturedRequests[1].params.payload?.contains("copy") == true)
        #expect(longPress.succeeded)
        #expect(copy.succeeded)
    }

    @Test("autocomplete effects reuse the existing core reducer")
    func autocompleteEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequest: LogseqChatRPCRequest?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequest = request
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(
                id: 15,
                kind: "choose-outliner-autocomplete",
                text: "page-a"
            )
        )
        let request = try #require(capturedRequest)

        #expect(request.params.action == "outlinerEvent")
        #expect(request.params.payload?.contains("chooseAutocomplete") == true)
        #expect(request.params.payload?.contains("page-a") == true)
        #expect(resolution.succeeded)
    }

    @Test("autosave effects reuse the existing core save action")
    func autosaveEffectsUseCoreOutlinerEvent() async throws {
        var capturedRequest: LogseqChatRPCRequest?
        let executor = LGChatCoreEffectExecutor { request in
            capturedRequest = request
            return "{\"apiVersion\":1,\"ok\":true,\"result\":null}"
        }

        let resolution = await executor.execute(
            LGChatEffect(id: 0, kind: "save-outliner-editing", text: "")
        )
        let request = try #require(capturedRequest)

        #expect(request.params.action == "outlinerEvent")
        #expect(request.params.payload?.contains("saveEditing") == true)
        #expect(resolution.succeeded)
    }

    @Test("delivers each core platform command revision exactly once")
    func deliversPlatformCommandsOnce() throws {
        let native = LGChatNativeRuntimeProbe()
        let platformCommands = LGChatPlatformCommandHandlerProbe()
        let runtime = LGChatRuntime(
            native: native,
            platformCommandHandler: platformCommands
        )
        try runtime.start(platformCode: 2)
        let response = """
        {"apiVersion":1,"ok":true,"result":{
          "graphName":"Work","outlinerCommandRevision":7,
          "outlinerCommands":[{"type":"setClipboardText","text":"Copied"}]
        }}
        """

        try runtime.applyCoreResponse(response)
        try runtime.applyCoreResponse(response)

        #expect(platformCommands.batches.count == 1)
        #expect(platformCommands.batches[0].revision == 7)
        #expect(platformCommands.batches[0].graphName == "Work")
        #expect(platformCommands.batches[0].commands.map(\.type) == ["setClipboardText"])
    }

    @Test("routes core commands into platform services and presentation intents")
    func routesPlatformCommands() {
        var clipboardValues: [String] = []
        var hapticStyles: [String?] = []
        var presentations: [LGChatPlatformPresentation] = []
        let router = LGChatPlatformCommandRouter(
            setClipboardText: { clipboardValues.append($0) },
            performHaptic: { hapticStyles.append($0) },
            present: { presentations.append($0) }
        )

        router.handle(LGChatPlatformCommandBatch(
            revision: 8,
            graphName: "Work",
            commands: [
                LogseqOutlinerCommand(
                    type: "setClipboardReferences",
                    style: nil,
                    uuid: nil,
                    uuids: ["a", "b"],
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "setClipboardURLs",
                    style: nil,
                    uuid: nil,
                    uuids: ["a"],
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "haptic",
                    style: "selection",
                    uuid: nil,
                    uuids: nil,
                    text: nil
                ),
                LogseqOutlinerCommand(
                    type: "pickAttachment",
                    style: nil,
                    uuid: "target",
                    uuids: nil,
                    text: nil
                ),
            ]
        ))

        #expect(clipboardValues == [
            "[[a]]\n[[b]]",
            "logseq://graph/Work?block-id=a",
        ])
        #expect(hapticStyles == ["selection"])
        #expect(presentations == [.pickAttachment(blockID: "target")])
    }
}

private struct FlashcardReviewPayload: Decodable {
    let uuid: String
    let rating: String
    let now: Int64
    let operationId: String
}

private struct LGChatEffectResolutionProbe: Equatable {
    let id: Int
    let succeeded: Bool
    let message: String
}

private struct LGChatExtensionEventProbe: Equatable {
    let node: Int
    let identifier: String
    let name: String
    let text: String
    let value: Int
}

@MainActor
private final class LGChatEffectExecutorProbe: LGChatEffectExecuting {
    var effects: [LGChatEffect] = []

    func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution {
        effects.append(effect)
        return LGChatEffectResolution(succeeded: true, message: "core response")
    }
}

@MainActor
private final class LGChatPlatformCommandHandlerProbe: LGChatPlatformCommandHandling {
    var batches: [LGChatPlatformCommandBatch] = []

    func handle(_ batch: LGChatPlatformCommandBatch) {
        batches.append(batch)
    }
}

@MainActor
private final class LGChatNativeRuntimeProbe: LGChatNativeCalling {
    var startedPlatforms: [Int] = []
    var pressedNodes: [Int] = []
    var effects: [String] = []
    var resolutions: [LGChatEffectResolutionProbe] = []
    var appliedSnapshots: [String] = []
    var extensionEvents: [LGChatExtensionEventProbe] = []

    func initialize(platformCode: Int, hostCode: Int) -> String {
        startedPlatforms.append(platformCode)
        return """
        {"generation":1,"ops":[
          {"op":"create-node","id":1,"kind":"root"}
        ]}
        """
    }

    func press(node: Int) -> String {
        pressedNodes.append(node)
        return """
        {"generation":2,"ops":[
          {"op":"create-node","id":2,"kind":"text"},
          {"op":"set-prop","id":2,"property":"text","value":"Opened"},
          {"op":"insert-child","parent":1,"child":2,"index":0}
        ]}
        """
    }

    func longPress(node: Int) -> String { "" }
    func textChanged(node: Int, text: String) -> String { "" }
    func submit(node: Int) -> String { "" }
    func toggleChanged(node: Int, checked: Bool) -> String { "" }
    func change(node: Int) -> String { "" }
    func valueChanged(node: Int, value: Double) -> String { "" }
    func dismiss(node: Int) -> String { "" }
    func doublePress(node: Int) -> String { "" }
    func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String {
        extensionEvents.append(LGChatExtensionEventProbe(
            node: node,
            identifier: identifier,
            name: name,
            text: text,
            value: value
        ))
        return ""
    }
    func dispose() -> String { "" }
    func takeEffect() -> String {
        effects.isEmpty ? "" : effects.removeFirst()
    }
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        resolutions.append(LGChatEffectResolutionProbe(
            id: id,
            succeeded: succeeded,
            message: message
        ))
        return ""
    }
    func applySnapshot(_ response: String) -> String {
        appliedSnapshots.append(response)
        return ""
    }
}
