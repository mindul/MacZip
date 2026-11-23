// swift-tools-version:6.0
import PackageDescription

let settings: [SwiftSetting] = []

let package = Package(
    name: "MacZip",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MacZipCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(name: "MacZipApp", dependencies: ["MacZipCore"]),
        .executableTarget(name: "MacZipChecks", dependencies: ["MacZipCore"]),
    ],
    swiftLanguageModes: [.v5]
)
