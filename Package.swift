// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Scrolly",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Scrolly",
            path: "Sources/Scrolly",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
