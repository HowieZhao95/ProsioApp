import AVFoundation
import Foundation
import ProsioMeeting
import Testing

@Test func mixedMeetingAudioContainsBothTracks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "meeting-mix-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let mic = root.appending(path: "mic.caf")
    let system = root.appending(path: "system.caf")
    try writeTone(to: mic, frequency: 440)
    try writeTone(to: system, frequency: 880)
    let files = MeetingAudioFiles(microphone: mic, system: system, microphoneOffset: 0,
                                  systemOffset: 0.25, warning: nil)
    let output = try await MeetingCloudAudio.export(files, to: root.appending(path: "recognition.m4a"))
    #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1_000)
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(duration > 1.1)
    let decoded = try AVAudioFile(forReading: output)
    #expect(try rms(decoded, at: 0.05) > 0.01)
    #expect(try rms(decoded, at: 1.1) > 0.01)
    #expect(try toneStrength(decoded, at: 0.5, frequency: 440) > 0.01)
    #expect(try toneStrength(decoded, at: 0.5, frequency: 880) > 0.01)
}

private func rms(_ file: AVAudioFile, at seconds: Double) throws -> Double {
    file.framePosition = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
    try file.read(into: buffer, frameCount: 2048)
    let samples = buffer.floatChannelData![0]
    let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) }
    return sqrt(energy / Double(max(1, buffer.frameLength)))
}

private func toneStrength(_ file: AVAudioFile, at seconds: Double, frequency: Double) throws -> Double {
    file.framePosition = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    try file.read(into: buffer, frameCount: 4096)
    let samples = buffer.floatChannelData![0]
    let count = Int(buffer.frameLength)
    let sine = (0..<count).reduce(0.0) { total, index in
        total + Double(samples[index]) * sin(2 * Double.pi * frequency * Double(index) / file.processingFormat.sampleRate)
    }
    let cosine = (0..<count).reduce(0.0) { total, index in
        total + Double(samples[index]) * cos(2 * Double.pi * frequency * Double(index) / file.processingFormat.sampleRate)
    }
    return hypot(sine, cosine) * 2 / Double(max(1, count))
}

private func writeTone(to url: URL, frequency: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let frames: AVAudioFrameCount = 48_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for index in 0..<Int(frames) {
        samples[index] = Float(sin(2 * Double.pi * frequency * Double(index) / 48_000) * 0.1)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
