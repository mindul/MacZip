// swift-tools-version:6.0
import PackageDescription

let settings: [SwiftSetting] = []

let package = Package(
    name: "Maczip",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MaczipCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(name: "MaczipApp", dependencies: ["MaczipCore"]),
        .executableTarget(name: "MaczipChecks", dependencies: ["MaczipCore"]),
    ],
    swiftLanguageModes: [.v5]
)
