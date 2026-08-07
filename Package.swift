// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenCodeRemote",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenCodeRemote", targets: ["OpenCodeRemote"]),
        .library(name: "OpenCodeRemoteApp", targets: ["OpenCodeRemoteApp"]),
        .executable(name: "OpenCodeWidgets", targets: ["OpenCodeWidgets"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "OpenCodeRemote",
            dependencies: [
                .product(name: "Tagged", package: "swift-tagged"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
            ],
            path: "Sources/OpenCodeRemote",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-enable-actor-data-race-checks"]),
            ]
        ),
        .target(
            name: "OpenCodeRemoteApp",
            dependencies: [
                "OpenCodeRemote",
            ],
            path: "Sources/OpenCodeRemoteApp",
            exclude: ["Resources/Info.plist", "Resources/PrivacyInfo.xcprivacy"],
            resources: [.process("Resources/Assets.xcassets")],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-enable-actor-data-race-checks"]),
            ]
        ),
        .executableTarget(
            name: "OpenCodeWidgets",
            dependencies: [
                "OpenCodeRemote",
            ],
            path: "Sources/OpenCodeWidgets",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-enable-actor-data-race-checks"]),
            ]
        ),
        .executableTarget(
            name: "MockServer",
            path: "Tools/MockServer"
        ),
        .executableTarget(
            name: "LiveE2E",
            dependencies: [
                "OpenCodeRemote",
            ],
            path: "Tools/LiveE2E",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-enable-actor-data-race-checks"]),
            ]
        ),
        .testTarget(
            name: "OpenCodeRemoteTests",
            dependencies: [.target(name: "OpenCodeRemote")],
            path: "Tests/OpenCodeRemoteTests",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-enable-actor-data-race-checks"]),
            ]
        ),
    ]
)
