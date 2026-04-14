// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "wuhu-ai",
  platforms: [
    .macOS(.v14),
    .iOS(.v16),
  ],
  products: [
    .library(name: "AI", targets: ["AI"]),
    .library(name: "AICore", targets: ["AICore"]),
    .library(name: "JSONUtilities", targets: ["JSONUtilities"]),
    .library(name: "FlavorResponses", targets: ["FlavorResponses"]),
    .library(name: "FlavorCompletions", targets: ["FlavorCompletions"]),
    .library(name: "FlavorAnthropicMessages", targets: ["FlavorAnthropicMessages"]),
    .library(name: "WuhuAI", targets: ["WuhuAI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch", .upToNextMinor(from: "0.2.0")),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.11.0"),
  ],
  targets: [
    .target(
      name: "JSONUtilities",
      path: "AlignedTargets/JSONUtilities/Sources"
    ),
    .target(
      name: "AICore",
      dependencies: [
        "JSONUtilities",
      ],
      path: "AlignedTargets/AICore/Sources"
    ),
    .target(
      name: "FlavorResponses",
      dependencies: [
        "AICore",
        "JSONUtilities",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
      path: "AlignedTargets/FlavorResponses/Sources"
    ),
    .target(
      name: "FlavorCompletions",
      dependencies: [
        "AICore",
        "JSONUtilities",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Fetch", package: "wuhu-fetch"),
      ],
      path: "AlignedTargets/FlavorCompletions/Sources"
    ),
    .target(
      name: "FlavorAnthropicMessages",
      dependencies: [
        "AICore",
        "JSONUtilities",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Fetch", package: "wuhu-fetch"),
      ],
      path: "AlignedTargets/FlavorAnthropicMessages/Sources"
    ),
    .target(
      name: "AI",
      dependencies: [
        "AICore",
        "FlavorResponses",
        "FlavorCompletions",
        "FlavorAnthropicMessages",
      ],
      path: "AlignedTargets/AI/Sources"
    ),
    .target(
      name: "WuhuAI",
      dependencies: [
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
      path: "Sources/WuhuAI"
    ),
    .testTarget(
      name: "AITests",
      dependencies: [
        "AI",
        .product(name: "FetchURLSession", package: "wuhu-fetch"),
      ],
      path: "AlignedTargets/AI/Tests",
      exclude: [
        "IntegrationTests/Recordings",
        "IntegrationTests/llm-forward-proxy.py",
        "IntegrationTests/llm-forward-proxy.config.sample.json",
        "IntegrationTests/llm-forward-proxy.config.json",
        "IntegrationTests/image-test.jpg",
      ]
    ),
    .testTarget(
      name: "WuhuAITests",
      dependencies: [
        "WuhuAI",
        .product(name: "FetchURLSession", package: "wuhu-fetch"),
      ],
      path: "Tests/WuhuAITests",
      exclude: [
        "IntegrationTests/README.md",
        "IntegrationTests/llm-forward-proxy.py",
        "IntegrationTests/llm-forward-proxy.config.sample.json",
        "IntegrationTests/Recordings",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
