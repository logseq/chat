import LUIAppleBackend
import Observation
import SwiftUI

public enum LGChatRendererEventKind: Equatable, Sendable {
    case press
    case hold
    case textChanged
    case submit
    case toggleChanged
    case change
    case valueChanged
    case dismiss
    case doublePress
    case `extension`
}

public struct LGChatRendererEvent: Equatable, Sendable {
    public let kind: LGChatRendererEventKind
    public let nodeID: Int
    public let text: String?
    public let checked: Bool?
    public let value: Double?
    public let extensionIdentifier: String?
    public let extensionName: String?
    public let extensionValues: [String: LUIExtensionValue]?

    public init(
        kind: LGChatRendererEventKind,
        nodeID: Int,
        text: String? = nil,
        checked: Bool? = nil,
        value: Double? = nil,
        extensionIdentifier: String? = nil,
        extensionName: String? = nil,
        extensionValues: [String: LUIExtensionValue]? = nil
    ) {
        self.kind = kind
        self.nodeID = nodeID
        self.text = text
        self.checked = checked
        self.value = value
        self.extensionIdentifier = extensionIdentifier
        self.extensionName = extensionName
        self.extensionValues = extensionValues
    }
}

@MainActor
@Observable
public final class LGChatRenderer {
    public private(set) var rootID: Int?

    @ObservationIgnored
    public var onEvent: ((LGChatRendererEvent) -> Void)?

    @ObservationIgnored
    let backend: LUIAppleBackend

    public init() {
        let backend = LUIAppleBackend()
        self.backend = backend
        backend.onEvent = { [weak self] event in
            self?.receive(Self.map(event))
        }
    }

    public func apply(patchJSON: String) throws {
        try backend.apply(json: patchJSON)
        rootID = backend.rootIDs.first
    }

    func receiveForTesting(_ event: LGChatRendererEvent) {
        receive(event)
    }

    private func receive(_ event: LGChatRendererEvent) {
        onEvent?(event)
    }

    private static func map(_ event: LUIEvent) -> LGChatRendererEvent {
        switch event {
        case .press(let node):
            return LGChatRendererEvent(kind: .press, nodeID: node)
        case .hold(let node):
            return LGChatRendererEvent(kind: .hold, nodeID: node)
        case .textChanged(let node, let text):
            return LGChatRendererEvent(kind: .textChanged, nodeID: node, text: text)
        case .submit(let node):
            return LGChatRendererEvent(kind: .submit, nodeID: node)
        case .toggleChanged(let node, let checked):
            return LGChatRendererEvent(
                kind: .toggleChanged,
                nodeID: node,
                checked: checked
            )
        case .change(let node):
            return LGChatRendererEvent(kind: .change, nodeID: node)
        case .valueChanged(let node, let value):
            return LGChatRendererEvent(kind: .valueChanged, nodeID: node, value: value)
        case .dismiss(let node):
            return LGChatRendererEvent(kind: .dismiss, nodeID: node)
        case .doublePress(let node):
            return LGChatRendererEvent(kind: .doublePress, nodeID: node)
        case .extension(let node, let identifier, let name, let values):
            return LGChatRendererEvent(
                kind: .extension,
                nodeID: node,
                extensionIdentifier: identifier,
                extensionName: name,
                extensionValues: values
            )
        }
    }
}

public struct LGChatRendererRoot: View {
    private let renderer: LGChatRenderer

    public init(renderer: LGChatRenderer) {
        self.renderer = renderer
    }

    @ViewBuilder
    public var body: some View {
        if let rootID = renderer.rootID {
            LUISwiftUIRoot(backend: renderer.backend, rootID: rootID)
        } else {
            EmptyView()
        }
    }
}
