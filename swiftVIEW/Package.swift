// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftVIEW",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "swiftVIEW"
        )
    ]
)
