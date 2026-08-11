// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftSYSINFO",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "swiftSYSINFO",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
