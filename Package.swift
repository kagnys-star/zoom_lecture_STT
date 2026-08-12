// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ZoomCaption",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(
      name: "ZoomCaption",
      path: "Sources/ZoomCaption",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
