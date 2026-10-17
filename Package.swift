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
            dependencies: ["MarkdownConversion", "Calculator", .product(name: "OpenAI", package: "OpenAI")],
            path: "Sources/Echo",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
