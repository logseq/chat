// swift-tools-version: 6.1

import PackageDescription

let version = "2.41.0"
let releaseBaseURL = "https://releases.amplify.aws/aws-sdk-ios"

let package = Package(
    name: "LogseqCognitoSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AWSCore", targets: ["AWSCore"]),
        .library(
            name: "AWSCognitoIdentityProvider",
            targets: ["AWSCognitoIdentityProviderTarget"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "AWSCore",
            url: "\(releaseBaseURL)/AWSCore-\(version).zip",
            checksum: "8a42c3da7efdc47b7b7e40a3cac0f1c29bc7bd0020d630fc1bd31e29caffdb3c"
        ),
        .binaryTarget(
            name: "AWSCognitoIdentityProviderASF",
            url: "\(releaseBaseURL)/AWSCognitoIdentityProviderASF-\(version).zip",
            checksum: "1171b85fc49464118b8bca6c9cfb529805eb207f4efc63e1127370dba5d11a30"
        ),
        .binaryTarget(
            name: "AWSCognitoIdentityProvider",
            url: "\(releaseBaseURL)/AWSCognitoIdentityProvider-\(version).zip",
            checksum: "bedd65dca74dd4fdf649b9d29c31e74637f839c0f73e63999d30ca675973f792"
        ),
        .target(
            name: "AWSCognitoIdentityProviderTarget",
            dependencies: [
                "AWSCore",
                "AWSCognitoIdentityProviderASF",
                "AWSCognitoIdentityProvider",
            ]
        ),
    ]
)
