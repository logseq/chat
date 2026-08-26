import Foundation
import LUIAppleBackend
import Observation
import LogseqChatModel

@MainActor
public protocol LGChatNativeCalling {
    func initialize(platformCode: Int, hostCode: Int) -> String
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

public struct LGChatEffect: Decodable, Equatable, Sendable {
    public let id: Int
    public let kind: String
    public let text: String
    public let uuid: String?
    public let value: Int?

    public init(
        id: Int,
        kind: String,
        text: String,
        uuid: String? = nil,
        value: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.uuid = uuid
        self.value = value
    }
}

public enum LGChatEffectOutput: Equatable, Sendable {
    case coreResponse
    case hostUpdate(String)
    case discard
}

public struct LGChatEffectResolution: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let output: LGChatEffectOutput

    public init(
        succeeded: Bool,
        message: String,
        output: LGChatEffectOutput = .coreResponse
    ) {
        self.succeeded = succeeded
        self.message = message
        self.output = output
    }
}

public struct LGChatSettingsPayload: Decodable, Equatable, Sendable {
    public let appearance: String
    public let language: String
    public let spellCheck: Bool
    public let autoCorrection: Bool
    public let sidebarTabs: [String]
    public let baseURL: String
}

public struct LGChatRuntimeLogPayload: Codable, Equatable, Sendable {
    public let id: String
    public let level: String
    public let source: String
    public let timestamp: String
    public let message: String
}

@MainActor
public final class LGChatPlatformEffectHandler: LGChatEffectExecuting {
    private let saveSettings: @MainActor (LGChatSettingsPayload) async throws -> Void
    private let runtimeLog: LogseqRuntimeLog
    private let copyText: @MainActor (String) -> Void
    private let signOut: @MainActor () async -> Void
    private let graphEffect: (@MainActor (LGChatEffect) async -> LGChatEffectResolution)?
    private let presentAttachment: (@MainActor (String) async -> Bool)?

    public init(
        saveSettings: @escaping @MainActor (LGChatSettingsPayload) async throws -> Void,
        runtimeLog: LogseqRuntimeLog,
        copyText: @escaping @MainActor (String) -> Void,
        signOut: @escaping @MainActor () async -> Void,
        graphEffect: (@MainActor (LGChatEffect) async -> LGChatEffectResolution)? = nil,
        presentAttachment: (@MainActor (String) async -> Bool)? = nil
    ) {
        self.saveSettings = saveSettings
        self.runtimeLog = runtimeLog
        self.copyText = copyText
        self.signOut = signOut
        self.graphEffect = graphEffect
        self.presentAttachment = presentAttachment
    }

    public func execute(_ effect: LGChatEffect) async -> LGChatEffectResolution {
        do {
            switch effect.kind {
            case "save-settings":
                let settings = try JSONDecoder().decode(
                    LGChatSettingsPayload.self,
                    from: Data(effect.text.utf8)
                )
                try await saveSettings(settings)
                return LGChatEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "refresh-runtime-log":
                guard let source = LogseqRuntimeLogSource(rawValue: effect.text) else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Unknown runtime log source: \(effect.text)",
                        output: .discard
                    )
                }
                let flags = effect.value ?? 0
                let records = runtimeLog.records(
                    source: source,
                    errorsOnly: flags & 1 != 0,
                    newestFirst: flags & 2 != 0
                ).map { record in
                    LGChatRuntimeLogPayload(
                        id: String(record.id),
                        level: record.level.rawValue.uppercased(),
                        source: record.source.rawValue,
                        timestamp: String(record.timestampMilliseconds),
                        message: record.message
                    )
                }
                let data = try JSONEncoder().encode(records)
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw LGChatEffectEncodingError.invalidUTF8
                }
                return LGChatEffectResolution(
                    succeeded: true,
                    message: payload,
                    output: .hostUpdate("runtime-log")
                )
            case "copy-runtime-log":
                let records = try JSONDecoder().decode(
                    [LGChatRuntimeLogPayload].self,
                    from: Data(effect.text.utf8)
                )
                copyText(records.map { record in
                    "\(record.timestamp) \(record.level) \(record.source) \(record.message)"
                }.joined(separator: "\n"))
                return LGChatEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "sign-out":
                await signOut()
                return LGChatEffectResolution(
                    succeeded: true,
                    message: "",
                    output: .discard
                )
            case "present-attachment":
                guard let presentAttachment else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Attachment presentation is unavailable",
                        output: .discard
                    )
                }
                let succeeded = await presentAttachment(effect.text)
                return LGChatEffectResolution(
                    succeeded: succeeded,
                    message: succeeded ? "" : "Unknown attachment service: \(effect.text)",
                    output: .discard
                )
            case "open-graph", "unlock-graph", "create-graph", "delete-local-graph":
                guard let graphEffect else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Graph platform handling is unavailable",
                        output: .discard
                    )
                }
                return await graphEffect(effect)
            default:
                return LGChatEffectResolution(
                    succeeded: false,
                    message: "Unsupported platform effect: \(effect.kind)",
                    output: .discard
                )
            }
        } catch {
            return LGChatEffectResolution(
                succeeded: false,
                message: String(describing: error),
                output: .discard
            )
        }
    }
}

public struct LGChatPlatformCommandBatch: Equatable, Sendable {
    public let revision: Int
    public let graphName: String?
    public let commands: [LogseqOutlinerCommand]

    public init(
        revision: Int,
        graphName: String?,
        commands: [LogseqOutlinerCommand]
    ) {
        self.revision = revision
        self.graphName = graphName
        self.commands = commands
    }
}

private struct LGChatPendingHostUpdate {
    let kind: String
    let payload: String
}

@MainActor
public protocol LGChatPlatformCommandHandling: AnyObject {
    func handle(_ batch: LGChatPlatformCommandBatch)
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

private struct LGReviewFlashcardPayload: Encodable {
    let uuid: String
    let rating: String
    let now: Int64
    let operationId: String
}

private struct LGCreateGraphPayload: Encodable {
    let name: String
    let isEncrypted: Bool
}

private struct LGCoreEffectResponse: Decodable {
    let ok: Bool
    let error: LogseqChatCoreError?
}

private struct LGPlatformCommandResponse: Decodable {
    let result: Result?

    struct Result: Decodable {
        let graphName: String?
        let outlinerCommandRevision: Int?
        let outlinerCommands: [LogseqOutlinerCommand]?
        let outlinerState: OutlinerState?
    }

    struct OutlinerState: Decodable {
        let autocomplete: Autocomplete?
    }

    struct Autocomplete: Decodable {}
}

@MainActor
public final class LGChatCoreEffectExecutor: LGChatEffectExecuting {
    private let callCore: @MainActor (LogseqChatRPCRequest) async -> String
    private let deleteLocalGraph: (@MainActor (String) async -> String)?
    private let platformEffect: (@MainActor (LGChatEffect) async -> LGChatEffectResolution)?

    public init(
        callCore: @escaping @MainActor (LogseqChatRPCRequest) async -> String = { request in
            await LogseqChatCore.callAsync(request)
        }
    ) {
        self.deleteLocalGraph = nil
        self.platformEffect = nil
        self.callCore = callCore
    }

    public init(
        deleteLocalGraph: @escaping @MainActor (String) async -> String,
        callCore: @escaping @MainActor (LogseqChatRPCRequest) async -> String
    ) {
        self.deleteLocalGraph = deleteLocalGraph
        self.platformEffect = nil
        self.callCore = callCore
    }

    public init(
        platformEffect: @escaping @MainActor (LGChatEffect) async -> LGChatEffectResolution,
        callCore: @escaping @MainActor (LogseqChatRPCRequest) async -> String = { request in
            await LogseqChatCore.callAsync(request)
        }
    ) {
        self.deleteLocalGraph = nil
        self.platformEffect = platformEffect
        self.callCore = callCore
    }

    public init(
        deleteLocalGraph: @escaping @MainActor (String) async -> String,
        platformEffect: @escaping @MainActor (LGChatEffect) async -> LGChatEffectResolution,
        callCore: @escaping @MainActor (LogseqChatRPCRequest) async -> String = { request in
            await LogseqChatCore.callAsync(request)
        }
    ) {
        self.deleteLocalGraph = deleteLocalGraph
        self.platformEffect = platformEffect
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
        case "open-node":
            do {
                let payloadData = try JSONEncoder().encode(
                    LogseqNodeRouteRequest(uuid: effect.text)
                )
                guard let payload = String(data: payloadData, encoding: .utf8) else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Could not encode the node route payload as UTF-8"
                    )
                }
                request = LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "openNode", payload: payload)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "close-node":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "closeNode")
            )
        case "select-sidebar-page":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "selectPage", payload: effect.text)
            )
        case "clear-selected-page":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "clearSelectedPage")
            )
        case "load-flashcards":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(
                    action: "loadFlashcards",
                    payload: String(Int64(Date().timeIntervalSince1970 * 1_000))
                )
            )
        case "refresh-graphs":
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "refresh")
            )
        case "open-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "selectGraph", payload: effect.text)
            )
        case "unlock-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            request = LogseqChatRPCRequest(
                method: "dispatch",
                params: LogseqChatRPCParams(action: "unlockGraph", payload: effect.text)
            )
        case "create-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            do {
                let data = try JSONEncoder().encode(LGCreateGraphPayload(
                    name: effect.text,
                    isEncrypted: effect.value == 1
                ))
                guard let payload = String(data: data, encoding: .utf8) else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Could not encode the graph creation payload as UTF-8"
                    )
                }
                request = LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "createSyncGraph", payload: payload)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "delete-local-graph":
            if let platformEffect {
                return await platformEffect(effect)
            }
            guard let deleteLocalGraph else {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: "Local graph deletion is unavailable"
                )
            }
            return Self.resolution(from: await deleteLocalGraph(effect.text))
        case "save-settings", "refresh-runtime-log", "copy-runtime-log", "sign-out",
             "present-attachment":
            guard let platformEffect else {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: "Platform settings handling is unavailable"
                )
            }
            return await platformEffect(effect)
        case "review-flashcard":
            guard let uuid = effect.uuid else {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: "Flashcard review is missing its card UUID"
                )
            }
            do {
                let payload = LGReviewFlashcardPayload(
                    uuid: uuid,
                    rating: effect.text,
                    now: Int64(Date().timeIntervalSince1970 * 1_000),
                    operationId: UUID().uuidString.lowercased()
                )
                let data = try JSONEncoder().encode(payload)
                guard let payloadJSON = String(data: data, encoding: .utf8) else {
                    return LGChatEffectResolution(
                        succeeded: false,
                        message: "Could not encode the flashcard review payload as UTF-8"
                    )
                }
                request = LogseqChatRPCRequest(
                    method: "dispatch",
                    params: LogseqChatRPCParams(action: "reviewFlashcard", payload: payloadJSON)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "tap-outliner-block", "toggle-outliner-collapsed", "zoom-outliner-block",
             "long-press-outliner-block", "add-root-block":
            do {
                let eventType = switch effect.kind {
                case "toggle-outliner-collapsed": "toggleCollapsed"
                case "zoom-outliner-block": "zoomIn"
                case "long-press-outliner-block": "longPressBlock"
                case "add-root-block": "addRootBlock"
                default: "tapBlock"
                }
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: eventType, uuid: effect.text)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "outliner-toolbar":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "toolbar", action: effect.text)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "choose-outliner-autocomplete":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "chooseAutocomplete", value: effect.text)
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "save-outliner-editing":
            do {
                request = try Self.outlinerRequest(
                    LogseqOutlinerEvent(type: "saveEditing")
                )
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        case "change-outliner-text", "return-outliner-editor",
             "backspace-outliner-editor", "move-outliner-caret":
            guard let uuid = effect.uuid, let value = effect.value else {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: "The LG outliner effect is missing its UUID or integer value"
                )
            }
            let event: LogseqOutlinerEvent
            switch effect.kind {
            case "change-outliner-text":
                event = LogseqOutlinerEvent(
                    type: "textChanged",
                    uuid: uuid,
                    title: effect.text,
                    caretUTF16Offset: value
                )
            case "return-outliner-editor":
                event = LogseqOutlinerEvent(
                    type: "returnPressed",
                    uuid: uuid,
                    title: effect.text,
                    caretUTF16Offset: value
                )
            case "backspace-outliner-editor":
                event = LogseqOutlinerEvent(
                    type: "backspacePressed",
                    uuid: uuid,
                    title: effect.text,
                    selectionLength: value
                )
            default:
                event = LogseqOutlinerEvent(
                    type: "caretMoved",
                    uuid: uuid,
                    caretUTF16Offset: value
                )
            }
            do {
                request = try Self.outlinerRequest(event)
            } catch {
                return LGChatEffectResolution(
                    succeeded: false,
                    message: String(describing: error)
                )
            }
        default:
            return LGChatEffectResolution(
                succeeded: false,
                message: "Unsupported LG effect: \(effect.kind)"
            )
        }

        let responseJSON = await callCore(request)
        return Self.resolution(from: responseJSON)
    }

    private static func resolution(from responseJSON: String) -> LGChatEffectResolution {
        do {
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

    private static func outlinerRequest(
        _ event: LogseqOutlinerEvent
    ) throws -> LogseqChatRPCRequest {
        let payloadData = try JSONEncoder().encode(event)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw LGChatEffectEncodingError.invalidUTF8
        }
        return LogseqChatRPCRequest(
            method: "dispatch",
            params: LogseqChatRPCParams(action: "outlinerEvent", payload: payloadJSON)
        )
    }
}

private enum LGChatEffectEncodingError: Error {
    case invalidUTF8
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
    private weak var platformCommandHandler: (any LGChatPlatformCommandHandling)?

    @ObservationIgnored
    private var isDrainingEffects = false

    @ObservationIgnored
    private var pendingCoreResponses: [String] = []

    @ObservationIgnored
    private var pendingHostUpdates: [LGChatPendingHostUpdate] = []

    @ObservationIgnored
    private var lastPlatformCommandRevision = 0

    @ObservationIgnored
    private var outlinerAutosaveTask: Task<Void, Never>?

    @ObservationIgnored
    private var outlinerAutosavePending = false

    @ObservationIgnored
    private let outlinerAutosaveDelayNanoseconds: UInt64

    public init(
        native: any LGChatNativeCalling,
        effectExecutor: any LGChatEffectExecuting = LGChatCoreEffectExecutor(),
        platformCommandHandler: (any LGChatPlatformCommandHandling)? = nil,
        outlinerAutosaveDelayNanoseconds: UInt64 =
            LogseqOutlinerAutosavePolicy.serverSyncDelayNanoseconds(
                eventType: "textChanged"
            )
    ) {
        self.native = native
        self.effectExecutor = effectExecutor
        self.platformCommandHandler = platformCommandHandler
        self.outlinerAutosaveDelayNanoseconds = outlinerAutosaveDelayNanoseconds
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
            deliverPlatformCommands(from: response)
        }
        while !pendingHostUpdates.isEmpty {
            let update = pendingHostUpdates.removeFirst()
            try apply(native.applyHostUpdate(kind: update.kind, payload: update.payload))
        }
        scheduleEffectDrain()
    }

    public func stop() {
        guard isStarted else { return }
        cancelOutlinerAutosave()
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
        deliverPlatformCommands(from: response)
    }

    public func applyHostUpdate(kind: String, payload: String) throws {
        guard isStarted else {
            pendingHostUpdates.append(LGChatPendingHostUpdate(kind: kind, payload: payload))
            return
        }
        try apply(native.applyHostUpdate(kind: kind, payload: payload))
    }

    private func receive(_ event: LGChatRendererEvent) {
        let patch: String
        switch event.kind {
        case .press:
            patch = native.press(node: event.nodeID)
        case .longPress:
            patch = native.longPress(node: event.nodeID)
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
            guard let identifier = event.extensionIdentifier,
                  let name = event.extensionName,
                  let values = event.extensionValues else {
                lastError = "Invalid LG extension event"
                return
            }
            let text = Self.extensionString(values, name: "title")
                ?? Self.extensionString(values, name: "uuid")
                ?? ""
            let value = Self.extensionInt(values, name: "caret-utf16-offset")
                ?? Self.extensionInt(values, name: "selection-length")
                ?? 0
            patch = native.extensionEvent(
                node: event.nodeID,
                identifier: identifier,
                name: name,
                text: text,
                value: value
            )
        }

        do {
            try apply(patch)
            scheduleEffectDrain()
        } catch {
            lastError = String(describing: error)
        }
    }

    private static func extensionString(
        _ values: [String: LUIExtensionValue],
        name: String
    ) -> String? {
        guard let rawValue = values[name],
              case let .string(value) = rawValue else { return nil }
        return value
    }

    private static func extensionInt(
        _ values: [String: LUIExtensionValue],
        name: String
    ) -> Int? {
        guard let rawValue = values[name],
              case let .int(value) = rawValue else { return nil }
        return value
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
            if encoded.isEmpty {
                if outlinerAutosavePending {
                    outlinerAutosavePending = false
                    await executeOutlinerAutosave()
                    continue
                }
                return
            }

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

            cancelOutlinerAutosaveBeforeExecuting(effect)
            let resolution = await effectExecutor.execute(effect)
            do {
                try apply(native.resolveEffect(
                    id: effect.id,
                    succeeded: resolution.succeeded,
                    message: resolution.message
                ))
                if resolution.succeeded {
                    switch resolution.output {
                    case .coreResponse:
                        try apply(native.applySnapshot(resolution.message))
                        deliverPlatformCommands(from: resolution.message)
                        scheduleOutlinerAutosaveIfNeeded(
                            after: effect,
                            response: resolution.message
                        )
                    case let .hostUpdate(kind):
                        try apply(native.applyHostUpdate(
                            kind: kind,
                            payload: resolution.message
                        ))
                    case .discard:
                        break
                    }
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

    private func deliverPlatformCommands(from response: String) {
        guard let envelope = try? JSONDecoder().decode(
            LGPlatformCommandResponse.self,
            from: Data(response.utf8)
        ) else { return }
        guard let result = envelope.result,
              let revision = result.outlinerCommandRevision,
              revision > lastPlatformCommandRevision else { return }
        lastPlatformCommandRevision = revision
        guard let commands = result.outlinerCommands, !commands.isEmpty else { return }
        platformCommandHandler?.handle(LGChatPlatformCommandBatch(
            revision: revision,
            graphName: result.graphName,
            commands: commands
        ))
    }

    private func cancelOutlinerAutosaveBeforeExecuting(_ effect: LGChatEffect) {
        guard effect.kind.contains("outliner"),
              effect.kind != "move-outliner-caret" else { return }
        cancelOutlinerAutosave()
    }

    private func cancelOutlinerAutosave() {
        outlinerAutosaveTask?.cancel()
        outlinerAutosaveTask = nil
        outlinerAutosavePending = false
    }

    private func scheduleOutlinerAutosaveIfNeeded(
        after effect: LGChatEffect,
        response: String
    ) {
        let shouldSchedule: Bool
        switch effect.kind {
        case "choose-outliner-autocomplete":
            shouldSchedule = true
        case "change-outliner-text":
            shouldSchedule = !responseHasOutlinerAutocomplete(response)
        default:
            shouldSchedule = false
        }
        guard shouldSchedule else { return }
        outlinerAutosaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: outlinerAutosaveDelayNanoseconds)
            guard !Task.isCancelled else { return }
            outlinerAutosaveTask = nil
            outlinerAutosavePending = true
            scheduleEffectDrain()
        }
    }

    private func responseHasOutlinerAutocomplete(_ response: String) -> Bool {
        guard let envelope = try? JSONDecoder().decode(
            LGPlatformCommandResponse.self,
            from: Data(response.utf8)
        ) else { return false }
        return envelope.result?.outlinerState?.autocomplete != nil
    }

    private func executeOutlinerAutosave() async {
        let effect = LGChatEffect(id: 0, kind: "save-outliner-editing", text: "")
        let resolution = await effectExecutor.execute(effect)
        guard resolution.succeeded else {
            lastError = resolution.message
            return
        }
        do {
            try apply(native.applySnapshot(resolution.message))
            deliverPlatformCommands(from: resolution.message)
            lastError = nil
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
