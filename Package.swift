// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Echo",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Echo",
            path: "Sources/Echo"
        )
    ]
)
