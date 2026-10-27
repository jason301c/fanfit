// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FanFit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanFitCore"),
        .executableTarget(name: "fanfitd", dependencies: ["CSMC", "FanFitCore"]),
        .executableTarget(name: "FanFit", dependencies: ["FanFitCore"]),
        .testTarget(name: "FanFitCoreTests", dependencies: ["FanFitCore"]),
    ],
    swiftLanguageModes: [.v5]
)
