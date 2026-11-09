// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "zerOS",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "zerOS",
            path: "Sources/zerOS",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("FoundationModels"),
            ]
        )
    ]
)
