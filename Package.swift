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
    .library(name: "WuhuAI", targets: ["WuhuAI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch", branch: "main"),
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch-async-http-client", branch: "main"),
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.30.3"),
  ],
  targets: [
    .target(
      name: "WuhuAI",
      dependencies: [
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "FetchSSE", package: "wuhu-fetch"),
      ],
      path: "Sources/PiAI",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "WuhuAITests",
      dependencies: [
        "WuhuAI",
      ],
      path: "Tests/PiAITests",
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "WuhuAILiveTests",
      dependencies: [
        "WuhuAI",
        .product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch-async-http-client"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
      path: "Tests/PiAIAsyncHTTPClientTests",
      swiftSettings: strictConcurrency
    ),
  ]
)
