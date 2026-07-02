// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIInput",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIInput",
            path: "Sources/AIInput"
        )
    ]
)
