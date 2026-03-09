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
        .package(url: "https://github.com/phranck/TUIkit.git", from: "0.5.0"),
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
        // Workaround for Swift 6.2 Linux linker bug where
        // libswiftObservation.so references a non-exported symbol
        // from libswiftCore.so. See: https://github.com/swiftlang/swift/issues/75670
        .target(name: "CThreadingShim"),
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
                "PiAI",
                "CThreadingShim",
                .product(name: "TUIkit", package: "TUIkit"),
            ],
            swiftSettings: strictConcurrency
        ),
    ]
)
