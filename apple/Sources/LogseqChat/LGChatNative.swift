import Foundation
import LUIAppleBackend
import Observation
import LogseqChatModel

public protocol LGChatNativeCalling {
    func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String
    func appear(node: Int) -> String
    func press(node: Int) -> String
    func longPress(node: Int) -> String
    func textChanged(node: Int, text: String) -> String
    func submit(node: Int) -> String
    func toggleChanged(node: Int, checked: Bool) -> String
    func change(node: Int) -> String
    func valueChanged(node: Int, value: Double) -> String
    func dismiss(node: Int) -> String
    func doublePress(node: Int) -> String
    func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String
    func dispose() -> String
    func takeEffect() -> String
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String
    func applySnapshot(_ response: String) -> String
    func applyHostUpdate(kind: String, payload: String) -> String
}

public final class LGChatCoreNativeCaller: LGChatNativeCalling {
    private let core: LogseqChatCore

    public init(core: LogseqChatCore = LogseqChatCore.shared) {
        self.core = core
    }

    public func initialize(
        platformCode: Int,
        hostCode: Int,
        authenticationCode: Int
    ) -> String {
        core.logseq_chat_lui_initialize(
            platformCode,
            hostCode,
            authenticationCode
        )
    }

    public func appear(node: Int) -> String { core.logseq_chat_lui_appear(node) }
    public func press(node: Int) -> String { core.logseq_chat_lui_press(node) }
    public func longPress(node: Int) -> String { core.logseq_chat_lui_long_press(node) }
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
    public func extensionEvent(
        node: Int,
        identifier: String,
        name: String,
        text: String,
        value: Int
    ) -> String {
        core.logseq_chat_lui_extension_event(node, identifier, name, text, value)
    }
    public func dispose() -> String { core.logseq_chat_lui_dispose() }
    public func takeEffect() -> String { core.logseq_chat_lui_take_effect() }
    public func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        core.logseq_chat_lui_resolve_effect(id, succeeded, message)
    }
    public func applySnapshot(_ response: String) -> String {
        core.logseq_chat_lui_apply_snapshot(response)
    }
    public func applyHostUpdate(kind: String, payload: String) -> String {
        core.logseq_chat_lui_apply_host_update(kind, payload)
    }
}
