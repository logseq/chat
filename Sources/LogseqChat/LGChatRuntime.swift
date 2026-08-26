import Foundation
import Observation
import LogseqChatModel

@MainActor
public protocol LGChatNativeCalling {
    func initialize(platformCode: Int, hostCode: Int) -> String
    func press(node: Int) -> String
    func hold(node: Int) -> String
    func textChanged(node: Int, text: String) -> String
    func submit(node: Int) -> String
    func toggleChanged(node: Int, checked: Bool) -> String
    func change(node: Int) -> String
    func valueChanged(node: Int, value: Double) -> String
    func dismiss(node: Int) -> String
    func doublePress(node: Int) -> String
    func dispose() -> String
}

@MainActor
public final class LGChatCoreNativeCaller: LGChatNativeCalling {
    private let core: LogseqChatCore

    public init(core: LogseqChatCore = LogseqChatCore.shared) {
        self.core = core
    }

    public func initialize(platformCode: Int, hostCode: Int) -> String {
        core.logseq_chat_lui_initialize(platformCode, hostCode)
    }

    public func press(node: Int) -> String { core.logseq_chat_lui_press(node) }
    public func hold(node: Int) -> String { core.logseq_chat_lui_hold(node) }
    public func textChanged(node: Int, text: String) -> String {
        core.logseq_chat_lui_text_changed(node, text)
    }
    public func submit(node: Int) -> String { core.logseq_chat_lui_submit(node) }
    public func toggleChanged(node: Int, checked: Bool) -> String {
        core.logseq_chat_lui_toggle_changed(node, checked)
    }
    public func change(node: Int) -> String { core.logseq_chat_lui_change(node) }
    public func valueChanged(node: Int, value: Double) -> String {
        core.logseq_chat_lui_value_changed(node, value)
    }
    public func dismiss(node: Int) -> String { core.logseq_chat_lui_dismiss(node) }
    public func doublePress(node: Int) -> String {
        core.logseq_chat_lui_double_press(node)
    }
    public func dispose() -> String { core.logseq_chat_lui_dispose() }
}

@MainActor
@Observable
public final class LGChatRuntime {
    public let renderer: LGChatRenderer
    public private(set) var lastError: String?

    @ObservationIgnored
    private let native: any LGChatNativeCalling

    public init(native: any LGChatNativeCalling) {
        self.native = native
        renderer = LGChatRenderer()
        renderer.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    public func start(platformCode: Int, hostCode: Int = 1) throws {
        try apply(native.initialize(platformCode: platformCode, hostCode: hostCode))
    }

    public func stop() {
        do {
            try apply(native.dispose())
        } catch {
            lastError = String(describing: error)
        }
    }

    private func receive(_ event: LGChatRendererEvent) {
        let patch: String
        switch event.kind {
        case .press:
            patch = native.press(node: event.nodeID)
        case .hold:
            patch = native.hold(node: event.nodeID)
        case .textChanged:
            patch = native.textChanged(node: event.nodeID, text: event.text ?? "")
        case .submit:
            patch = native.submit(node: event.nodeID)
        case .toggleChanged:
            patch = native.toggleChanged(
                node: event.nodeID,
                checked: event.checked ?? false
            )
        case .change:
            patch = native.change(node: event.nodeID)
        case .valueChanged:
            patch = native.valueChanged(node: event.nodeID, value: event.value ?? 0.0)
        case .dismiss:
            patch = native.dismiss(node: event.nodeID)
        case .doublePress:
            patch = native.doublePress(node: event.nodeID)
        case .extension:
            lastError = "LG extension event routing is not configured"
            return
        }

        do {
            try apply(patch)
        } catch {
            lastError = String(describing: error)
        }
    }

    private func apply(_ patch: String) throws {
        guard !patch.isEmpty else { return }
        try renderer.apply(patchJSON: patch)
        lastError = nil
    }
}
