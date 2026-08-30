import LUIAppleBackend
import SwiftUI

enum LGChatNavigationSurfacePolicy {
    static func usesSystemGroupedBackground(contentPreference: Bool) -> Bool {
        contentPreference
    }

    static func bottomPadding(occupiesLayoutSpace: Bool) -> CGFloat {
        occupiesLayoutSpace ? 7 : 0
    }

    static func systemToolbarItemWidth(
        iconWidth: CGFloat,
        minimumHitTarget: CGFloat
    ) -> CGFloat {
        min(iconWidth, minimumHitTarget)
    }
}

@MainActor
enum LGChatNavigationExtension {
    static let identifier = "native-navigation-stack"
    static let fingerprint = "lui-extension-v1|23:native-navigation-stack|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],4:back[5:count:int:required]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "bottom-occupies-layout-space", kind: .bool, isRequired: true),
                    .init(name: "composer-dismissal-enabled", kind: .bool, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss-composer", fields: []),
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
            bottomOccupiesLayoutSpace: bottomOccupiesLayoutSpace,
            composerDismissalEnabled: composerDismissalEnabled,
            rootTransform: nil
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

    private var composerDismissalEnabled: Bool {
        guard case let .bool(value) = context.property("composer-dismissal-enabled") else {
            return false
        }
        return value
    }

}

@MainActor
enum LGChatSearchPresentationExtension {
    static let identifier = "native-search-presentation"
    static let fingerprint = "lui-extension-v1|26:native-search-presentation|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]"

    static func register(in registry: LUIAppleExtensionRegistry) throws {
        try registry.register(
            LUIAppleExtension(
                identifier: identifier,
                fingerprint: fingerprint,
                acceptsStandardChildren: true,
                properties: [
                    .init(name: "presented", kind: .bool, isRequired: true),
                    .init(name: "depth", kind: .int, isRequired: true),
                    .init(name: "query", kind: .string, isRequired: true),
                    .init(name: "title", kind: .string, isRequired: true),
                ],
                events: [
                    .init(name: "back", fields: [
                        .init(name: "count", kind: .int, isRequired: true),
                    ]),
                    .init(name: "dismiss", fields: []),
                    .init(name: "query-changed", fields: [
                        .init(name: "query", kind: .string, isRequired: true),
                    ]),
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
    #if !SKIP && os(iOS)
    @State private var nativeSearchPresented = true
    @FocusState private var searchFocused: Bool
    #endif

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
            bottomOccupiesLayoutSpace: false,
            composerDismissalEnabled: false,
            rootTransform: searchRootTransform
        )
    }

    private func searchRootTransform(_ content: AnyView) -> AnyView {
        #if !SKIP && os(iOS)
        if #available(iOS 26.0, *) {
            return AnyView(nativeBottomSearch(content))
        }
        return AnyView(nativeLegacySearch(content))
        #else
        return AnyView(nativeAutomaticSearch(content))
        #endif
    }

    private func nativeAutomaticSearch(_ content: AnyView) -> some View {
        content
            .searchable(
                text: queryBinding,
                placement: .automatic,
                prompt: "Search pages and blocks"
            )
    }

    #if !SKIP && os(iOS)
    private func nativeLegacySearch(_ content: AnyView) -> some View {
        content
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .automatic,
                prompt: "Search pages and blocks"
            )
            .onAppear {
                nativeSearchPresented = true
            }
    }

    @available(iOS 26.0, *)
    private func nativeBottomSearch(_ content: AnyView) -> some View {
        content
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: queryBinding,
                isPresented: nativeSearchPresentedBinding,
                placement: .toolbar,
                prompt: "Search pages and blocks"
            )
            .searchFocused($searchFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: exitSearch) {
                        Image("close", bundle: .module)
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 44)
                            .accessibilityIdentifier("button.search.close")
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Close search")
                    .accessibilityIdentifier("button.search.close")
                }
            }
            .onAppear {
                nativeSearchPresented = true
                DispatchQueue.main.async {
                    searchFocused = true
                }
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .tracking || newPhase == .interacting {
                    searchFocused = false
                }
            }
    }

    private func exitSearch() {
        searchFocused = false
        nativeSearchPresentedBinding.wrappedValue = false
    }

    private var nativeSearchPresentedBinding: Binding<Bool> {
        Binding(
            get: { nativeSearchPresented },
            set: { isPresented in
                nativeSearchPresented = isPresented
                if !isPresented {
                    DispatchQueue.main.async {
                        emitDismiss()
                    }
                }
            }
        )
    }
    #endif

    private var presented: Bool {
        guard case let .bool(value) = context.property("presented") else { return false }
        return value
    }

    private var depth: Int {
        guard case let .int(value) = context.property("depth") else { return 0 }
        return value
    }

    private var query: String {
        guard case let .string(value) = context.property("query") else { return "" }
        return value
    }

    private var searchTitle: String {
        guard case let .string(value) = context.property("title") else { return "Search" }
        return value
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { query },
            set: { newValue in
                emitQueryChanged(newValue)
            }
        )
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

    private func emitQueryChanged(_ query: String) {
        do {
            try context.emit(name: "query-changed", values: ["query": .string(query)])
        } catch {
            logger.error("Could not update native search query: \(String(describing: error))")
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
    let composerDismissalEnabled: Bool
    let rootTransform: ((AnyView) -> AnyView)?
    @State private var path: [Int] = []
    @State private var usesSystemGroupedBackground = false
    @AppStorage("logseq.appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        #if SKIP
        navigationLayout
        #else
        navigationLayout
            .onPreferenceChange(LUIListSurfacePreferenceKey.self) { usesSystemBackground in
                usesSystemGroupedBackground = usesSystemBackground
            }
        #endif
    }

    @ViewBuilder
    private var navigationLayout: some View {
        #if SKIP
        if bottomOccupiesLayoutSpace {
            VStack(spacing: 0) {
                navigationStack
                sizedBottomChrome
            }
        } else {
            navigationStack
                .overlay(alignment: .bottom) {
                    sizedBottomChrome
                }
        }
        #else
        navigationStack
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            .overlay(alignment: .bottom) {
                if !bottomOccupiesLayoutSpace {
                    sizedBottomChrome
                }
            }
            .background(routeBackground.ignoresSafeArea())
        #endif
    }

    private var navigationStack: some View {
        NavigationStack(path: pathBinding) {
            transformedRootContent
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(routeBackground)
                .overlay {
                    if composerDismissalEnabled {
                        #if SKIP
                        Color.clear
                            .onTapGesture {
                                emitDismissComposer()
                            }
                            .accessibilityLabel("Dismiss composer")
                            .accessibilityIdentifier("surface.composer.dismiss")
                        #else
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: emitDismissComposer)
                            .accessibilityLabel("Dismiss composer")
                            .accessibilityIdentifier("surface.composer.dismiss")
                        #endif
                    }
                }
                .navigationDestination(for: Int.self) { childID in
                    context.content(for: childID)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .background(routeBackground)
                        .navigationTitle(navigationTitle)
                        #if !SKIP && os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            destinationTrailingToolbar
                        }
                }
                .toolbar {
                    if let toolbarStartIndex {
                        #if SKIP
                        ToolbarItemGroup(placement: .navigation) {
                            context.content(for: context.childIDs[toolbarStartIndex])
                            context.content(for: context.childIDs[toolbarStartIndex + 1])
                        }
                        #else
                        if #available(iOS 26.0, macOS 26.0, *) {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: context.childIDs[toolbarStartIndex])
                                    .modifier(LGChatLiquidGlassSurface(shape: .circle))
                                    .frame(width: LGChatNavigationSurfacePolicy.systemToolbarItemWidth(
                                        iconWidth: 24,
                                        minimumHitTarget: 44
                                    ))
                            }
                            .sharedBackgroundVisibility(.hidden)
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: context.childIDs[toolbarStartIndex + 1])
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: context.childIDs[toolbarStartIndex])
                            }
                            ToolbarItem(placement: rootLeadingToolbarPlacement) {
                                context.content(for: context.childIDs[toolbarStartIndex + 1])
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        #endif
                        #if SKIP
                        ToolbarItemGroup(placement: .primaryAction) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                        #else
                        #if os(iOS)
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                        #else
                        ToolbarItemGroup(placement: .primaryAction) {
                            context.content(for: context.childIDs[toolbarStartIndex + 2])
                            context.content(for: context.childIDs[toolbarStartIndex + 3])
                        }
                        #endif
                        #endif
                    }
                }
                #if !SKIP && os(iOS)
                .toolbar(.visible, for: .navigationBar)
                #endif
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(routeBackground.ignoresSafeArea())
        #if !SKIP && os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(routeBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
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

    private var transformedRootContent: AnyView {
        rootTransform?(rootContent) ?? rootContent
    }

    private var themePalette: LogseqThemePalette {
        LogseqThemePolicy.palette(
            mode: LogseqThemeMode(rawValue: appearance) ?? .system,
            systemIsDark: colorScheme == .dark
        )
    }

    private var routeBackground: Color {
        #if !SKIP && os(iOS)
        if LGChatNavigationSurfacePolicy.usesSystemGroupedBackground(
            contentPreference: usesSystemGroupedBackground
        ) {
            return Color(uiColor: .systemGroupedBackground)
        }
        #endif
        return themePalette.background
    }

    private var navigationTitle: String {
        guard case let .string(value) = context.property("title") else { return "" }
        return value
    }

    @ToolbarContentBuilder
    private var destinationTrailingToolbar: some ToolbarContent {
        #if SKIP
        ToolbarItemGroup(placement: .primaryAction) {
            if let toolbarStartIndex {
                context.content(for: context.childIDs[toolbarStartIndex + 2])
                context.content(for: context.childIDs[toolbarStartIndex + 3])
            }
        }
        #else
        if let toolbarStartIndex {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                context.content(for: context.childIDs[toolbarStartIndex + 2])
                context.content(for: context.childIDs[toolbarStartIndex + 3])
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                context.content(for: context.childIDs[toolbarStartIndex + 2])
                context.content(for: context.childIDs[toolbarStartIndex + 3])
            }
            #endif
        }
        #endif
    }

    private var bottomChrome: AnyView {
        guard let bottomChromeIndex,
              context.childIDs.count > bottomChromeIndex
        else { return AnyView(EmptyView()) }
        return context.content(for: context.childIDs[bottomChromeIndex])
    }

    @ViewBuilder
    private var sizedBottomChrome: some View {
        if bottomOccupiesLayoutSpace {
            bottomChrome
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGChatBottomChromeSurface())
                .modifier(LGChatBottomChromeHitTarget(isRounded: true))
                .padding(.horizontal, 16)
                .padding(.bottom, LGChatNavigationSurfacePolicy.bottomPadding(
                    occupiesLayoutSpace: true
                ))
        } else {
            bottomChrome
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LGChatBottomChromeHitTarget(isRounded: false))
        }
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

    private var rootLeadingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var pathBinding: Binding<[Int]> {
        Binding(
            get: { path },
            set: { newPath in
                let removedCount = max(0, path.count - newPath.count)
                path = newPath
                if removedCount > 0 {
                    Task { @MainActor in
                        await Task.yield()
                        emitBack(count: removedCount)
                    }
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

    private func emitDismissComposer() {
        do {
            try context.emit(name: "dismiss-composer", values: [:])
        } catch {
            logger.error("Could not dismiss composer: \(String(describing: error))")
        }
    }
}

private struct LGChatBottomChromeSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if SKIP
        content
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
        }
        #endif
    }
}

private struct LGChatBottomChromeHitTarget: ViewModifier {
    let isRounded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if SKIP
        content.onTapGesture {}
        #else
        if isRounded {
            content
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .onTapGesture {}
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture {}
        }
        #endif
    }
}
