// swift-tools-version: 6.2
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend",
        "-strict-concurrency=complete",
        "-Xfrontend",
        "-warn-concurrency",
    ]),
]

let package = Package(
    name: "wuhu-ai",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "PiAI", targets: ["PiAI"]),
        .library(name: "EffectLoops", targets: ["EffectLoops"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "PiAI",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "PiAITests",
            dependencies: [
                "PiAI",
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "EffectLoops",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "EffectLoopsTests",
            dependencies: [
                "EffectLoops",
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "EffectLoopsExamples",
            dependencies: [
                "EffectLoops",
                "PiAI",
            ],
            swiftSettings: strictConcurrency
        ),
        .target(name: "CFlush"),
        .executableTarget(
            name: "ChatCLI",
            dependencies: [
                "EffectLoops",
                "PiAI",
                "CFlush",
            ],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "EffectLoopsDemo",
            dependencies: [
                "EffectLoops",
            ],
            swiftSettings: strictConcurrency
        ),
    ]
)
