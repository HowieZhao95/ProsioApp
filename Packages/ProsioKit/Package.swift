// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProsioKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ProsioCore", targets: ["ProsioCore"]),
        .library(name: "ProsioAudio", targets: ["ProsioAudio"]),
        .library(name: "ProsioTranscription", targets: ["ProsioTranscription"]),
    ],
    targets: [
        // Domain types, contracts, dictation state machine, stores, settings, backend client.
        .target(name: "ProsioCore"),
        // Microphone capture -> 24 kHz PCM16 mono chunks + levels.
        .target(name: "ProsioAudio", dependencies: ["ProsioCore"]),
        // Cloud (Vercel AI Gateway) and on-device (SpeechAnalyzer) engines.
        .target(name: "ProsioTranscription", dependencies: ["ProsioCore"]),
        .testTarget(name: "ProsioCoreTests", dependencies: ["ProsioCore"]),
        .testTarget(name: "ProsioTranscriptionTests", dependencies: ["ProsioTranscription", "ProsioCore"]),
        // Added by speech agent (P1.2): tests for SilenceTrimmer / OggOpusEncoder. Additive only —
        // no other targets changed. See final report, "Contract change request".
        .testTarget(name: "ProsioAudioTests", dependencies: ["ProsioAudio"]),
    ],
    swiftLanguageModes: [.v6]
)
