// swift-tools-version: 6.1
import PackageDescription
import Foundation

let logseqChatNativeLinkInputs = ProcessInfo.processInfo.environment["LOGSEQ_CHAT_NATIVE_LINK_INPUTS"]?
    .split(separator: ":")
    .map(String.init) ?? []
let logseqChatSimulatorEntitlements = ProcessInfo.processInfo.environment["LOGSEQ_CHAT_SIMULATOR_ENTITLEMENTS"]
let logseqChatLinkerSettings: [LinkerSetting] = logseqChatNativeLinkInputs.isEmpty ? [] : [
    .unsafeFlags(logseqChatNativeLinkInputs, .when(platforms: [.iOS])),
    .linkedFramework("Foundation", .when(platforms: [.iOS])),
    .linkedFramework("Security", .when(platforms: [.iOS])),
    .linkedLibrary("sqlite3", .when(platforms: [.iOS])),
    .linkedLibrary("ffi", .when(platforms: [.iOS]))
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
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "LogseqChatShell", targets: ["LogseqChatShell"]),
        .library(name: "LogseqChat", type: .static, targets: ["LogseqChat"]),
        .library(name: "LogseqChatModel", type: .dynamic, targets: ["LogseqChatModel"]),
    ],
    dependencies: [
        .package(url: "ssh://git@github.com/logseq/lui.git", revision: "6dfddf7"),
        .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
        .package(url: "https://github.com/appstefan/highlightswift.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "LogseqChatShell",
            dependencies: ["LogseqChat"],
            path: "App/Sources",
            linkerSettings: logseqChatShellLinkerSettings
        ),
        .target(name: "LogseqChat", dependencies: [
            "LogseqChatModel",
            .product(name: "LUIAppleBackendStatic", package: "lui"),
            .product(
                name: "SwiftUIMath",
                package: "swiftui-math",
                condition: .when(platforms: [.iOS])
            ),
            .product(
                name: "HighlightSwift",
                package: "highlightswift",
                condition: .when(platforms: [.iOS])
            )
        ],
        resources: [.process("Resources")],
        linkerSettings: logseqChatLinkerSettings),
        .testTarget(
            name: "LogseqChatTests",
            dependencies: ["LogseqChat", .product(name: "LUIAppleBackendStatic", package: "lui")],
            resources: [.process("Resources")]
        ),
        .target(name: "LogseqChatModel", dependencies: [
            "LogseqChatCoreABI"
        ], resources: [.process("Resources")],
        swiftSettings: logseqChatCoreSwiftSettings),
        .target(
            name: "LogseqChatCoreABI",
            path: "Sources/LogseqChatCoreABI",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "LogseqChatModelTests",
            dependencies: ["LogseqChatModel"],
            resources: [.process("Resources")]
        ),
    ]
)
