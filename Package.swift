// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeybaseMinimal",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MinimalCore", targets: ["MinimalCore"]),
        .executable(name: "KeybaseMinimal", targets: ["MinimalKeybase"])
    ],
    targets: [
        .target(name: "CKeybaseProcess", publicHeadersPath: "include"),
        .target(name: "MinimalCore", dependencies: ["CKeybaseProcess"], resources: [.process("Resources")]),
        .executableTarget(name: "MinimalKeybase", dependencies: ["MinimalCore", "CKeybaseProcess"]),
        .testTarget(name: "MinimalCoreTests", dependencies: ["MinimalCore"])
    ],
    swiftLanguageModes: [.v5]
)
