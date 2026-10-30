// swift-tools-version:5.10
import PackageDescription

// Native WebRTC integration tests use the exact transport source built by the app.
let package = Package(
    name: "MultiKVMTransport",
    platforms: [.macOS(.v13), .iOS(.v17)],
    dependencies: [
        .package(path: "../swift"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "156.0.0"),
    ],
    targets: [
        .target(
            name: "MultiKVMTransport",
            dependencies: [
                .product(name: "MultiKVMCore", package: "swift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "MultiKVM",
            exclude: ["Info.plist", "PrivacyInfo.xcprivacy", "InputController.swift", "RootView.swift", "SessionController.swift", "VideoRenderer.swift"],
            sources: ["PeerLink.swift"]
        ),
        .testTarget(name: "TransportTests", dependencies: ["MultiKVMTransport"], path: "TransportTests"),
    ]
)
