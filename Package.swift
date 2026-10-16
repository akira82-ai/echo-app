// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Echo",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "MarkdownConversion", resources: [.process("Resources")]),
        .executableTarget(
            name: "MarkdownProbe",
            dependencies: ["MarkdownConversion"],
            path: "Sources/MarkdownProbe"
        ),
        .executableTarget(
            name: "Echo",
            dependencies: ["MarkdownConversion"],
            path: "Sources/Echo",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
