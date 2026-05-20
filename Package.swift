// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "wuhu-ai",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "WuhuAI", targets: ["WuhuAI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-json.git", .upToNextMinor(from: "0.1.3")),
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch.git", .upToNextMinor(from: "0.2.2")),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ... "5.0.0"),
  ],
  targets: [
    .target(
      name: "WuhuAI",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
        .product(name: "JSONValue", package: "wuhu-json"),
      ],
      path: "Sources/WuhuAI"
    ),
    .testTarget(
      name: "WuhuAITests",
      dependencies: [
        "WuhuAI",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "JSONValue", package: "wuhu-json"),
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchURLSession", package: "wuhu-fetch"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Tests/WuhuAITests",
      exclude: [
        "IntegrationTests/Recordings",
        "IntegrationTests/panda.jpg",
        "TestHelpers/RECORDING.md",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
