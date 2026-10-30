// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MultiKVMCore",
    products: [
        .library(name: "MultiKVMCore", targets: ["MultiKVMCore"]),
    ],
    targets: [
        .target(name: "MultiKVMCore"),
        .testTarget(name: "MultiKVMCoreTests", dependencies: ["MultiKVMCore"]),
    ]
)
