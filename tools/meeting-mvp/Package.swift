// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingMVP",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: ".vendor/FluidAudio"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingMVP",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
