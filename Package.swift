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
        .executableTarget(name: "Broschy"),
        .executableTarget(name: "BroschyCLI")
    ],
    swiftLanguageModes: [.v5]
)
