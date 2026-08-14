// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftXLOGO",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "swiftXLOGO",
            path: "Sources/swiftXLOGO"
        )
    ]
)
