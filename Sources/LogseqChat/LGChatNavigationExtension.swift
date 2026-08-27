import LUIAppleBackend
import SwiftUI

@MainActor
enum LGChatNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none|events:4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "depth", kind: .int, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                ]
            ) { context in
                AnyView(LGChatNavigationStack(context: context))
            }
        )
    }
}

@MainActor
private struct LGChatNavigationStack: View {
    let context: LUIAppleExtensionViewContext
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: pathBinding) {
            rootContent
                .navigationDestination(for: Int.self) { childID in
                    context.content(for: childID)
                }
        }
        .onAppear {
            path = desiredPath
        }
        .onChange(of: desiredPath) { _, newPath in
            if path != newPath {
                path = newPath
            }
        }
    }

    private var rootContent: AnyView {
        guard let rootID = context.childIDs.first else {
            return AnyView(EmptyView())
        }
        return context.content(for: rootID)
    }

    private var desiredPath: [Int] {
        let childIDs = context.childIDs
        let availableDepth = max(0, childIDs.count - 1)
        let requestedDepth = max(0, depth)
        let retainedDepth = min(requestedDepth, availableDepth)
        var result: [Int] = []
        for index in 0..<retainedDepth {
            result.append(childIDs[index + 1])
        }
        return result
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var pathBinding: Binding<[Int]> {
        Binding(
            get: { path },
            set: { newPath in
                let removedCount = max(0, path.count - newPath.count)
                path = newPath
                if removedCount > 0 {
                    emitBack(count: removedCount)
                }
            }
        )
    }

    private func emitBack(count: Int) {
        do {
            try context.emit(name: "back", values: ["count": .int(count)])
        } catch {
            logger.error("Could not synchronize native navigation: \(String(describing: error))")
        }
    }
}
