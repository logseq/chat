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
}
