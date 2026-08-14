// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "logseq-chat",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LogseqChat", type: .dynamic, targets: ["LogseqChat"]),
        .library(name: "LogseqChatModel", type: .dynamic, targets: ["LogseqChatModel"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.5"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-ffi.git", from: "1.0.0"),
        .package(path: "Vendor/LogseqCognitoSDK")
    ],
    targets: [
        .target(name: "LogseqChat", dependencies: [
            "LogseqChatModel",
            .product(name: "SkipUI", package: "skip-ui"),
            .product(name: "AWSCore", package: "LogseqCognitoSDK", condition: .when(platforms: [.iOS])),
            .product(name: "AWSCognitoIdentityProvider", package: "LogseqCognitoSDK", condition: .when(platforms: [.iOS]))
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "LogseqChatTests", dependencies: [
            "LogseqChat",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "LogseqChatModel", dependencies: [
            "LogseqChatCoreABI",
            .product(name: "SkipFoundation", package: "skip-foundation"),
            .product(name: "SkipModel", package: "skip-model"),
            .product(name: "SkipFFI", package: "skip-ffi")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
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
