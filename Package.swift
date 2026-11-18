// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "RelayWorkspace",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "RelayCore", targets: ["RelayCore"]),
    .executable(name: "relay", targets: ["RelayCLI"]),
    .executable(name: "RelayDesktop", targets: ["RelayDesktop"]),
  ],
  targets: [
    .target(name: "RelayCore"),
    .executableTarget(name: "RelayCLI", dependencies: ["RelayCore"]),
    .executableTarget(
      name: "RelayDesktop", dependencies: ["RelayCore"], path: "App", exclude: ["Assets.xcassets"]),
    .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
  ]
)
