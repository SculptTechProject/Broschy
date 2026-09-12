// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Broschy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Broschy", targets: ["Broschy"]),
        .executable(name: "broschy-cli", targets: ["BroschyCLI"])
    ],
    targets: [
        .target(name: "AgentBridge"),
        .executableTarget(name: "Broschy", dependencies: ["AgentBridge"]),
        .executableTarget(name: "BroschyCLI", dependencies: ["AgentBridge"])
    ],
    swiftLanguageModes: [.v5]
)
