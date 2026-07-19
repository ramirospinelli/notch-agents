// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NotchAgents", targets: ["NotchAgents"])],
    targets: [
        .executableTarget(name: "NotchAgents", swiftSettings: [.unsafeFlags(["-parse-as-library"])]),
        .testTarget(name: "NotchAgentsTests", dependencies: ["NotchAgents"])
    ]
)
