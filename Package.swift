// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LarkAssistant",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "LarkAssistant",
            path: "Sources/LarkAssistant"
        )
    ]
)
