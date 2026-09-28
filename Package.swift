// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuMetrics",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MenuMetrics",
            path: "Sources/MenuMetrics",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
