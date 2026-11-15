// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Echo",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/Expression.git", from: "0.13.0"),
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.3")
    ],
    targets: [
        // Official Sparkle 2.8.1 artifact and checksum from its SwiftPM manifest.
        .binaryTarget(name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "995f913935fe903d50b3be5344fc52a638f56b39ef7984bf7a44244786d28638"),
        .target(name: "Calculator", dependencies: [.product(name: "Expression", package: "Expression")]),
        .executableTarget(name: "CalculatorProbe", dependencies: ["Calculator"]),
        .target(name: "MarkdownConversion", resources: [.process("Resources")]),
        .executableTarget(
            name: "MarkdownProbe",
            dependencies: ["MarkdownConversion"],
            path: "Sources/MarkdownProbe"
        ),
        .executableTarget(
            name: "Echo",
            dependencies: ["MarkdownConversion", "Calculator", .product(name: "OpenAI", package: "OpenAI"), "Sparkle"],
            path: "Sources/Echo",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
