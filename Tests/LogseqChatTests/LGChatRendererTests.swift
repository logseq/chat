import Testing
@testable import LogseqChat

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
}

@MainActor
private final class LGChatNativeRuntimeProbe: LGChatNativeCalling {
    var startedPlatforms: [Int] = []
    var pressedNodes: [Int] = []

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
    func dispose() -> String { "" }
}
