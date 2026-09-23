import LUIAppleBackend
import SwiftUI

@MainActor
enum LGChatOverflowMenuExtension {
    static let identifier = "native-overflow-menu"
    static let fingerprint = "lui-extension-v1|20:native-overflow-menu|profiles:android/flutter,ios/swiftui|standard-children:0|children:|properties:14:favorite-label:string:required:none,16:settings-visible:bool:required:none,20:page-actions-visible:bool:required:none|events:5:share[],6:delete[],8:favorite[],8:settings[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                properties: [
                    .init(name: "page-actions-visible", kind: .bool, isRequired: true),
                    .init(name: "favorite-label", kind: .string, isRequired: true),
                    .init(name: "settings-visible", kind: .bool, isRequired: true),
                ],
                events: [
                    .init(name: "favorite", fields: []),
                    .init(name: "share", fields: []),
                    .init(name: "delete", fields: []),
                    .init(name: "settings", fields: []),
                ]
            ) { context in
                AnyView(LGChatOverflowMenu(context: context))
            }
        )
    }
}

@MainActor
private struct LGChatOverflowMenu: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        if settingsVisible && !pageActionsVisible {
            Button {
                emit("settings")
            } label: {
                ZStack {
                    Circle()
                        .stroke(lineWidth: 2)
                    Image(systemName: "gearshape")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .frame(width: 24, height: 24)
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(.primary)
            .accessibilityLabel(Text("Settings", bundle: .module))
            .accessibilityIdentifier("button.connection")
        } else {
            menuBody
        }
    }

    private var menuBody: some View {
        Menu {
            if pageActionsVisible {
                Button {
                    emit("favorite")
                } label: {
                    Text(verbatim: favoriteLabel)
                }
                Button {
                    emit("share")
                } label: {
                    Text("Share", bundle: .module)
                }
                Button(role: .destructive) {
                    emit("delete")
                } label: {
                    Text("Delete", bundle: .module)
                }
            }
            if settingsVisible {
                Button {
                    emit("settings")
                } label: {
                    Text("Settings", bundle: .module)
                }
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(lineWidth: 2)
                Image("more_horiz", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
            .frame(width: 24, height: 24)
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text("More", bundle: .module))
        .accessibilityIdentifier("button.connection")
    }

    private var pageActionsVisible: Bool {
        guard case let .bool(value) = context.property("page-actions-visible") else {
            return false
        }
        return value
    }

    private var favoriteLabel: String {
        guard case let .string(value) = context.property("favorite-label") else {
            return "Favorite"
        }
        return value
    }

    private var settingsVisible: Bool {
        guard case let .bool(value) = context.property("settings-visible") else {
            return false
        }
        return value
    }

    private func emit(_ name: String) {
        do {
            try context.emit(name: name, values: [:])
        } catch {
            logger.error("Could not emit overflow menu event: \(String(describing: error))")
        }
    }
}
