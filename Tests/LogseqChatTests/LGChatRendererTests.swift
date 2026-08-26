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

    @Test("routes native editor extension events through LG")
    func routesOutlinerEditorExtensionEvents() throws {
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

        #expect(native.outlinerEditorEvents == [
            LGChatOutlinerEditorEventProbe(
                node: 17,
                name: "text-change",
                text: "Updated",
                value: 7
            )
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
}

private struct LGChatEffectResolutionProbe: Equatable {
    let id: Int
    let succeeded: Bool
    let message: String
}

private struct LGChatOutlinerEditorEventProbe: Equatable {
    let node: Int
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
private final class LGChatNativeRuntimeProbe: LGChatNativeCalling {
    var startedPlatforms: [Int] = []
    var pressedNodes: [Int] = []
    var effects: [String] = []
    var resolutions: [LGChatEffectResolutionProbe] = []
    var appliedSnapshots: [String] = []
    var outlinerEditorEvents: [LGChatOutlinerEditorEventProbe] = []

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

    func hold(node: Int) -> String { "" }
    func textChanged(node: Int, text: String) -> String { "" }
    func submit(node: Int) -> String { "" }
    func toggleChanged(node: Int, checked: Bool) -> String { "" }
    func change(node: Int) -> String { "" }
    func valueChanged(node: Int, value: Double) -> String { "" }
    func dismiss(node: Int) -> String { "" }
    func doublePress(node: Int) -> String { "" }
    func outlinerEditorEvent(node: Int, name: String, text: String, value: Int) -> String {
        outlinerEditorEvents.append(LGChatOutlinerEditorEventProbe(
            node: node,
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
