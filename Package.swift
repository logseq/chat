// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription
import Foundation

let logseqChatNativeLinkInputs = ProcessInfo.processInfo.environment["LOGSEQ_CHAT_NATIVE_LINK_INPUTS"]?
    .split(separator: ":")
    .map(String.init) ?? []
let logseqChatSimulatorEntitlements = ProcessInfo.processInfo.environment["LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS"]
let luiPackageDependency: Package.Dependency
if let localLUIPath = ProcessInfo.processInfo.environment["LUI_PACKAGE_PATH"] {
    luiPackageDependency = .package(name: "lui", path: localLUIPath)
} else {
    luiPackageDependency = .package(
        url: "ssh://git@github.com/tiensonqin/lui.git",
        revision: "3e6531c32d9189375cade718717d2b081bed8616"
    )
}
let logseqChatLinkerSettings: [LinkerSetting] = logseqChatNativeLinkInputs.isEmpty ? [] : [
    .unsafeFlags(logseqChatNativeLinkInputs, .when(platforms: [.iOS])),
    .linkedFramework("Foundation", .when(platforms: [.iOS])),
    .linkedFramework("Security", .when(platforms: [.iOS])),
    .linkedLibrary("sqlite3", .when(platforms: [.iOS]))
]
let logseqChatCoreSwiftSettings: [SwiftSetting] = logseqChatNativeLinkInputs.isEmpty ? [] : [
    .define("LOGSEQ_CHAT_CORE", .when(platforms: [.iOS]))
]
let logseqChatShellLinkerSettings: [LinkerSetting] = logseqChatSimulatorEntitlements.map {
    [.unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
        "-Xlinker", $0
    ], .when(platforms: [.iOS]))]
} ?? []

let package = Package(
    name: "logseq-chat",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .executable(name: "LogseqChatShell", targets: ["LogseqChatShell"]),
        .library(name: "LogseqChat", type: .static, targets: ["LogseqChat"]),
        .library(name: "LogseqChatModel", type: .dynamic, targets: ["LogseqChatModel"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.5"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-ffi.git", from: "1.0.0"),
        luiPackageDependency,
        .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
        .package(url: "https://github.com/appstefan/highlightswift.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "LogseqChatShell",
            dependencies: ["LogseqChat"],
            path: "Darwin/Sources",
            linkerSettings: logseqChatShellLinkerSettings
        ),
        .target(name: "LogseqChat", dependencies: [
            "LogseqChatModel",
            .product(name: "LUIAppleBackendStatic", package: "lui"),
            .product(name: "SkipUI", package: "skip-ui"),
            .product(
                name: "SwiftUIMath",
                package: "swiftui-math",
                condition: .when(platforms: [.iOS, .macOS])
            ),
            .product(
                name: "HighlightSwift",
                package: "highlightswift",
                condition: .when(platforms: [.iOS, .macOS])
            )
        ],
        resources: [.process("Resources")],
        linkerSettings: logseqChatLinkerSettings,
        plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "LogseqChatTests", dependencies: [
            "LogseqChat",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "LogseqChatModel", dependencies: [
            "LogseqChatCoreABI",
            .product(name: "SkipFoundation", package: "skip-foundation"),
            .product(name: "SkipModel", package: "skip-model"),
            .product(name: "SkipFFI", package: "skip-ffi")
        ], resources: [.process("Resources")],
        swiftSettings: logseqChatCoreSwiftSettings,
        plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(
            name: "LogseqChatCoreABI",
            path: "Sources/LogseqChatCoreABI",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(name: "LogseqChatModelTests", dependencies: [
            "LogseqChatModel",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
