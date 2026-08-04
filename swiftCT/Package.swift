// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swiftCT",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "swiftCT",
            dependencies: ["SwiftTerm"]
        )
    ]
)
