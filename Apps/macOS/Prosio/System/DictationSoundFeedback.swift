import AppKit

/// Cached, quiet 90 ms cues; playback never waits on the microphone or transcription.
@MainActor
final class DictationSoundFeedback {
    private let startSound = DictationSoundFeedback.makeSound(from: 620, to: 880)
    private let stopSound = DictationSoundFeedback.makeSound(from: 880, to: 620)

    func playStart() {
        stopSound?.stop()
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        startSound?.stop()
        stopSound?.stop()
        stopSound?.play()
    }

    private static func makeSound(from start: Double, to end: Double) -> NSSound? {
        let sampleRate = 44_100
        let duration = 0.09
        let count = Int(Double(sampleRate) * duration)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let progress = Double(index) / Double(count - 1)
            // Smooth attack and release prevent clicks; low amplitude keeps the cue subtle.
            let envelope = pow(sin(.pi * progress), 2)
            let phase = 2 * Double.pi * (start * time + (end - start) * time * time / (2 * duration))
            append(Int16(sin(phase) * envelope * 0.12 * Double(Int16.max)))
        }
        return NSSound(data: data)
    }
}
