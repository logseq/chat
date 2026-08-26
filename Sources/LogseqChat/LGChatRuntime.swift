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
    func takeEffect() -> String
    func resolveEffect(id: Int, succeeded: Bool, message: String) -> String
    func applySnapshot(_ response: String) -> String
}

public struct LGChatEffect: Decodable, Equatable, Sendable {
    public let id: Int
    public let kind: String
    public let text: String
}

public struct LGChatEffectResolution: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

@MainActor
public protocol LGChatEffectExecuting {
    func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution
}

private struct LGSendCapturePayload: Encodable {
    let text: String
    let uuid: String
    let now: Int64
}

private struct LGCoreEffectResponse: Decodable {
    let ok: Bool
    let error: LogseqChatCoreError?
}

@MainActor
public final class LGChatCoreEffectExecutor: LGChatEffectExecuting {
    private let callCore: (LogseqChatRPCRequest) async -> String

    public init(
        callCore: @escaping (LogseqChatRPCRequest) async -> String = { request in
            await LogseqChatCore.callAsync(request)
        }
    ) {
        self.callCore = callCore
    }

    public func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution {
        let request: LogseqChatRPCRequest
        switch effect.kind {
        case "send-capture":
            do {
                let payload = LGSendCapturePayload(
                    text: effect.text,
                    uuid: UUID().uuidString.lowercased(),
                    now: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                let payloadData = try JSONEncoder().encode(payload)
                guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Could not encode the capture payload as UTF-8"
                    )
                }
                request = LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "send", payload: payloadJSON)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "search-nodes":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "searchNodes", payload: effect.text)
            )
        default:
            return LGChatEffectResolution(
                succeeded: false,
                message: "Unsupported LG effect: \(effect.kind)"
            )
        }

        do {
            let responseJSON = await callCore(request)
            let response = try JSONDecoder().decode(
                LGCoreEffectResponse.self,
                from: Data(responseJSON.utf8)
            )
            if response.ok {
                return LGChatEffectResolution(succeeded: true, message: responseJSON)
            }
            return LGChatEffectResolution(
                succeeded: false,
                message: response.error?.message ?? "The OCaml core rejected the effect"
            )
        } catch {
            return LGChatEffectResolution(
                succeeded: false,
                message: String(describing: error)
            )
        }
    }
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
    public func takeEffect() -> String { core.logseq_chat_lui_take_effect() }
    public func resolveEffect(id: Int, succeeded: Bool, message: String) -> String {
        core.logseq_chat_lui_resolve_effect(id, succeeded, message)
    }
    public func applySnapshot(_ response: String) -> String {
        core.logseq_chat_lui_apply_snapshot(response)
    }
}

@MainActor
@Observable
public final class LGChatRuntime {
    public let renderer: LGChatRenderer
    public private(set) var lastError: String?
    public private(set) var isStarted = false

    @ObservationIgnored
    private let native: any LGChatNativeCalling

    @ObservationIgnored
    private let effectExecutor: any LGChatEffectExecuting

    @ObservationIgnored
    private var isDrainingEffects = false

    @ObservationIgnored
    private var pendingCoreResponses: [String] = []

    public init(
        native: any LGChatNativeCalling,
        effectExecutor: any LGChatEffectExecuting = LGChatCoreEffectExecutor()
    ) {
        self.native = native
        self.effectExecutor = effectExecutor
        renderer = LGChatRenderer()
        renderer.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    public func start(platformCode: Int, hostCode: Int = 1) throws {
        guard !isStarted else { return }
        try apply(native.initialize(platformCode: platformCode, hostCode: hostCode))
        isStarted = true
        while !pendingCoreResponses.isEmpty {
            let response = pendingCoreResponses.removeFirst()
            try apply(native.applySnapshot(response))
        }
        scheduleEffectDrain()
    }

    public func stop() {
        guard isStarted else { return }
        do {
            try apply(native.dispose())
        } catch {
            lastError = String(describing: error)
        }
        isStarted = false
    }

    public func applyCoreResponse(_ response: String) throws {
        guard isStarted else {
            pendingCoreResponses.append(response)
            return
        }
        try apply(native.applySnapshot(response))
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
            scheduleEffectDrain()
        } catch {
            lastError = String(describing: error)
        }
    }

    private func scheduleEffectDrain() {
        guard !isDrainingEffects else { return }
        isDrainingEffects = true
        Task { [weak self] in
            await self?.drainEffects()
        }
    }

    private func drainEffects() async {
        defer { isDrainingEffects = false }
        while true {
            let encoded = native.takeEffect()
            guard !encoded.isEmpty else { return }

            let effect: LGChatEffect
            do {
                effect = try JSONDecoder().decode(
                    LGChatEffect.self,
                    from: Data(encoded.utf8)
                )
            } catch {
                lastError = "Invalid LG effect: \(String(describing: error))"
                return
            }

            let resolution = await effectExecutor.execute(effect)
            do {
                try apply(native.resolveEffect(
                    id: effect.id,
                    succeeded: resolution.succeeded,
                    message: resolution.message
                ))
                if resolution.succeeded {
                    try apply(native.applySnapshot(resolution.message))
                }
                lastError = resolution.succeeded ? nil : resolution.message
            } catch {
                lastError = String(describing: error)
                return
            }
        }
    }

    func drainEffectsForTesting() async {
        await drainEffects()
    }

    private func apply(_ patch: String) throws {
        guard !patch.isEmpty else { return }
        try renderer.apply(patchJSON: patch)
        lastError = nil
    }
}
