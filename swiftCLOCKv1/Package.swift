// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftCLOCKv1",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "swiftCLOCKv1"
        )
    ]
)
