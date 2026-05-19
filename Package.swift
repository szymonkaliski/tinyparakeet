// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "tinyparakeet",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
  ],
  targets: [
    .executableTarget(
      name: "tinyparakeet",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
