// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SherpaOnnxMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SherpaOnnx", targets: ["SherpaOnnx"])
    ],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxBinary",
            path: "Binaries/SherpaOnnxC.xcframework"
        ),
        .binaryTarget(
            name: "OnnxRuntimeMacOS",
            path: "Binaries/OnnxRuntimeMacOS.xcframework"
        ),
        .target(
            name: "SherpaOnnxC",
            dependencies: ["SherpaOnnxBinary"],
            path: "Sources/SherpaOnnxC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: ["SherpaOnnxC", "OnnxRuntimeMacOS"],
            path: "Sources/SherpaOnnx",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
