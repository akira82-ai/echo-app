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
        // Official Sparkle 2.10.1 artifact and checksum from its SwiftPM manifest.
        .binaryTarget(name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"),
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
