// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "wuhu-ai",
  platforms: [
    .macOS(.v14),
    .iOS(.v16),
  ],
  products: [
    .library(name: "WuhuAI", targets: ["WuhuAI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch", branch: "main"),
  ],
  targets: [
    .target(
      name: "WuhuAI",
      dependencies: [
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
      path: "Sources/WuhuAI"
    ),
    .testTarget(
      name: "WuhuAITests",
      dependencies: [
        "WuhuAI",
      ],
      path: "Tests/WuhuAITests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
