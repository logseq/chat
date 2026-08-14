// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription
import Foundation

let logseqChatNativeLinkInputs = ProcessInfo.processInfo.environment["LOGSEQ_CHAT_NATIVE_LINK_INPUTS"]?
    .split(separator: ":")
    .map(String.init) ?? []
let logseqChatLinkerSettings: [LinkerSetting] = logseqChatNativeLinkInputs.isEmpty ? [] : [
    .unsafeFlags(logseqChatNativeLinkInputs, .when(platforms: [.iOS])),
    .linkedFramework("Foundation", .when(platforms: [.iOS])),
    .linkedLibrary("sqlite3", .when(platforms: [.iOS]))
]

let package = Package(
    name: "logseq-chat",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .executable(name: "LogseqChatShell", targets: ["LogseqChatShell"]),
        .library(name: "LogseqChat", type: .dynamic, targets: ["LogseqChat"]),
        .library(name: "LogseqChatModel", type: .dynamic, targets: ["LogseqChatModel"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.5"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-ffi.git", from: "1.0.0"),
        .package(url: "https://github.com/aws-amplify/amplify-swift", exact: "2.60.1"),
        .package(url: "https://github.com/aws-amplify/amplify-ui-swift-authenticator", exact: "1.3.1")
    ],
    targets: [
        .executableTarget(
            name: "LogseqChatShell",
            dependencies: ["LogseqChat"],
            path: "Darwin/Sources"
        ),
        .target(name: "LogseqChat", dependencies: [
            "LogseqChatModel",
            .product(name: "SkipUI", package: "skip-ui"),
            .product(name: "Amplify", package: "amplify-swift", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "AWSPluginsCore", package: "amplify-swift", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "AWSCognitoAuthPlugin", package: "amplify-swift", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "Authenticator", package: "amplify-ui-swift-authenticator", condition: .when(platforms: [.iOS, .macOS]))
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
        swiftSettings: [.define("LOGSEQ_CHAT_CORE", .when(platforms: [.iOS]))],
        plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(
            name: "LogseqChatCoreABI",
            path: "Sources/LogseqChatCoreABI",
            publicHeadersPath: "include"
        ),
        .testTarget(name: "LogseqChatModelTests", dependencies: [
            "LogseqChatModel",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
