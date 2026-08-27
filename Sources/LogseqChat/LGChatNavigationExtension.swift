import LUIAppleBackend
import SwiftUI

@MainActor
enum LGChatNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none|events:4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "bottom-occupies-layout-space", kind: .bool, isRequired: true),
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

    var body: some View {
        LGChatNavigationContent(
            context: context,
            rootIndex: 0,
            routeStartIndex: 6,
            depth: depth,
            synchronizationName: "navigation",
            toolbarStartIndex: 1,
            bottomChromeIndex: 5,
            bottomOccupiesLayoutSpace: bottomOccupiesLayoutSpace
        )
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var bottomOccupiesLayoutSpace: Bool {
        guard case let .bool(value) = context.property("bottom-occupies-layout-space") else {
            return false
        }
        return value
    }

}

@MainActor
enum LGChatSearchPresentationExtension {
    static let identifier = "native-search-presentation"
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,9:presented:bool:required:none|events:4:back[5:count:int:required],7:dismiss[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "presented", kind: .bool, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss", fields: []),
                ]
            ) { context in
                AnyView(LGChatSearchPresentation(context: context))
            }
        )
    }
}

@MainActor
private struct LGChatSearchPresentation: View {
    let context: LUIAppleExtensionViewContext

    var body: some View {
        baseContent
            #if os(macOS)
            .sheet(isPresented: presentedBinding) {
                searchNavigation
            }
            #else
            .fullScreenCover(isPresented: presentedBinding) {
                searchNavigation
            }
            #endif
    }

    private var baseContent: AnyView {
        guard let childID = context.childIDs.first else {
            return AnyView(EmptyView())
        }
        return context.content(for: childID)
    }

    private var searchNavigation: some View {
        LGChatNavigationContent(
            context: context,
            rootIndex: 1,
            routeStartIndex: 2,
            depth: depth,
            synchronizationName: "search navigation",
            toolbarStartIndex: nil,
            bottomChromeIndex: nil,
            bottomOccupiesLayoutSpace: false
        )
    }

    private var presented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var presentedBinding: Binding<Bool> {
        Binding(
            get: { presented },
            set: { newValue in
                if presented && !newValue {
                    emitDismiss()
                }
            }
        )
    }

    private func emitDismiss() {
        do {
            try context.emit(name: "dismiss", values: [:])
        } catch {
            logger.error("Could not dismiss native search: \(String(describing: error))")
        }
    }
}

@MainActor
private struct LGChatNavigationContent: View {
    let context: LUIAppleExtensionViewContext
    let rootIndex: Int
    let routeStartIndex: Int
    let depth: Int
    let synchronizationName: String
    let toolbarStartIndex: Int?
    let bottomChromeIndex: Int?
    let bottomOccupiesLayoutSpace: Bool
    @State private var path: [Int] = []

    @ViewBuilder
    var body: some View {
        #if SKIP
        if bottomOccupiesLayoutSpace {
            VStack(spacing: 0) {
                navigationStack
                bottomChrome
            }
        } else {
            navigationStack
                .overlay(alignment: .bottom) {
                    bottomChrome
                }
        }
        #else
        navigationStack
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomOccupiesLayoutSpace {
                    bottomChrome
                }
            }
            .overlay(alignment: .bottom) {
                if !bottomOccupiesLayoutSpace {
                    bottomChrome
                }
            }
        #endif
    }

    private var navigationStack: some View {
        NavigationStack(path: pathBinding) {
            rootContent
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .navigationDestination(for: Int.self) { childID in
                    context.content(for: childID)
                }
                .toolbar {
                    if let toolbarStartIndex {
                        #if SKIP
                        ToolbarItemGroup(placement: .navigation) {
                            context.content(for: context.childIDs[toolbarStartIndex])
                            context.content(for: context.childIDs[toolbarStartIndex + 1])
                        }
                        #else
                        ToolbarItem(placement: .navigation) {
                            context.content(for: context.childIDs[toolbarStartIndex])
                        }
                        if #available(iOS 26.0, macOS 26.0, *) {
                            ToolbarItem(placement: .navigation) {
                                context.content(for: context.childIDs[toolbarStartIndex + 1])
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .navigation) {
                                context.content(for: context.childIDs[toolbarStartIndex + 1])
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        #endif
                        ToolbarItemGroup(placement: .primaryAction) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                    }
                }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
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
        guard context.childIDs.count > rootIndex else {
            return AnyView(EmptyView())
        }
        return context.content(for: context.childIDs[rootIndex])
    }

    private var bottomChrome: AnyView {
        guard let bottomChromeIndex,
              context.childIDs.count > bottomChromeIndex
        else { return AnyView(EmptyView()) }
        return context.content(for: context.childIDs[bottomChromeIndex])
    }

    private var desiredPath: [Int] {
        let childIDs = context.childIDs
        let availableDepth = max(0, childIDs.count - routeStartIndex)
        let retainedDepth = min(max(0, depth), availableDepth)
        var result: [Int] = []
        for index in 0..<retainedDepth {
            result.append(childIDs[index + routeStartIndex])
        }
        return result
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
            logger.error(
                "Could not synchronize native \(synchronizationName): \(String(describing: error))"
            )
        }
    }
}
