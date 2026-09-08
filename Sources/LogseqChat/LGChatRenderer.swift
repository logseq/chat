import LUIAppleBackend
import Observation
import SwiftUI

public enum LGChatRendererEventKind: Equatable, Sendable {
    case appear
    case press
    case longPress
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

enum LGChatIconPolicy {
    static var icons: [String: LUIAppleIconSource] {
        var result: [String: LUIAppleIconSource] = [
            "calendar": .assetName("calendar"),
            "add": .assetName("plus"),
            "arrow-up": .systemName("arrow.up"),
            "chevron-down": .assetName("chevron_down"),
            "document": .assetName("document"),
            "disclosure-down": .assetName("disclosure_down"),
            "disclosure-right": .assetName("disclosure_right"),
            "refresh": .systemName("arrow.clockwise"),
            "graph-locked": .systemName("lock"),
            "flashcards": .assetName("flashcards"),
            "folder": .assetName("folder"),
            "graph-local": .assetName("folder"),
            "graph-remote": .assetName("upload"),
            "history": .assetName("history"),
            "more-horiz": .assetName("more_horiz"),
            "search": .assetName("search"),
            "sidebar-toggle": .assetName("sidebar_toggle"),
            "star": .assetName("star"),
            "status-dot": .assetName("status_dot"),
            "outliner-bullet": .assetName("outliner_bullet"),
            "task-backlog": .assetName("task_backlog"),
            "task-canceled": .assetName("task_canceled"),
            "task-doing": .assetName("task_doing"),
            "task-done": .assetName("task_done"),
            "task-review": .assetName("task_review"),
            "task-todo": .assetName("task_todo"),
            "toolbar-attachment": .assetName("paperclip"),
            "toolbar-audio": .assetName("toolbar_audio"),
            "toolbar-camera": .assetName("camera"),
            "composer-photo": .systemName("photo.on.rectangle.angled"),
            "toolbar-copy": .systemName("doc.on.doc"),
            "toolbar-copy-reference": .systemName("r.square"),
            "toolbar-copy-url": .systemName("link"),
            "toolbar-delete": .systemName("trash"),
            "toolbar-hide-keyboard": .assetName("toolbar_hide_keyboard"),
            "toolbar-indent": .assetName("toolbar_indent"),
            "toolbar-outdent": .assetName("toolbar_outdent"),
            "toolbar-tag": .assetName("toolbar_tag"),
            "toolbar-task": .assetName("task_done"),
            "toolbar-unselect": .systemName("xmark"),
            "trash": .systemName("trash"),
        ]
        result["calendar"] = .systemName("calendar")
        result["add"] = .systemName("plus")
        result["document"] = .systemName("doc.text")
        result["folder"] = .systemName("folder")
        result["graph-local"] = .systemName("cylinder.split.1x2")
        result["graph-remote"] = .systemName("icloud")
        result["history"] = .systemName("clock")
        result["search"] = .systemName("magnifyingglass")
        result["star"] = .systemName("star")
        result["toolbar-attachment"] = .systemName("paperclip")
        result["toolbar-audio"] = .systemName("mic")
        result["toolbar-camera"] = .systemName("camera")
        result["toolbar-hide-keyboard"] = .systemName("keyboard.chevron.compact.down")
        result["toolbar-indent"] = .systemName("arrow.right")
        result["toolbar-outdent"] = .systemName("arrow.left")
        result["toolbar-tag"] = .systemName("number")
        result["toolbar-task"] = .systemName("checkmark.square")
        return result
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
        let backend = Self.makeBackend()
        self.backend = backend
        backend.onEvent = { [weak self] event in
            self?.receive(Self.map(event))
        }
    }

    private static func makeBackend() -> LUIAppleBackend {
        do {
            return try LUIAppleBackend(
                appIcons: LGChatIconPolicy.icons,
                appIconBundle: .module,
                extensionRegistry: LGChatExtensionRegistry.makeRegistry()
            )
        } catch {
            preconditionFailure(
                "Invalid LG chat extension registry: \(String(describing: error))"
            )
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
        guard let onEvent else { return }
        onEvent(event)
    }

    private static func map(_ event: LUIEvent) -> LGChatRendererEvent {
        switch event {
        case .appear(let node):
            return LGChatRendererEvent(kind: .appear, nodeID: node)
        case .press(let node):
            return LGChatRendererEvent(kind: .press, nodeID: node)
        case .longPress(let node):
            return LGChatRendererEvent(kind: .longPress, nodeID: node)
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
