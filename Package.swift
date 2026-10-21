// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ContextGauge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ContextGauge", path: "Sources/ContextGauge"),
        .testTarget(name: "ContextGaugeTests", dependencies: ["ContextGauge"], path: "Tests/ContextGaugeTests"),
    ]
)
