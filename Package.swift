// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NMS",
    platforms: [
        .macOS(.v14) // SwiftData requires macOS 14+
    ],
    targets: [
        .executableTarget(
            name: "NMS",
            path: "Sources/NMS"
        )
    ]
)
