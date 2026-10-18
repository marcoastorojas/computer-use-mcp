// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "computer-use-mcp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "computer-use-mcp",
            path: "Sources/computer-use-mcp"
        )
    ]
)
