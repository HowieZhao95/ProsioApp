import AVFoundation
import Foundation
import Speech

/// A copied PCM frame is safe to queue after the capture callback returns.
public struct MeetingAudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

public final class MeetingLiveCaptions: @unchecked Sendable {
    private let frames: AsyncStream<MeetingAudioFrame>
    private let input: AsyncStream<MeetingAudioFrame>.Continuation
    private var task: Task<Void, Never>?

    public init() {
        (frames, input) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
    }

    public func append(_ frame: MeetingAudioFrame) { input.yield(frame) }
    public func finish() { input.finish() }

    public static func prepare(locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw MeetingError.unavailable("Live captions are unsupported for \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
        try await AssetInventory.reserve(locale: supported)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Called once per track. The callback receives provisional text, never the durable final draft.
    public func start(locale: Locale, onUpdate: @escaping @Sendable (String) -> Void) {
        task = Task { [frames] in
            do {
                guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
                let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
                try await AssetInventory.reserve(locale: supported)
                if await AssetInventory.status(forModules: [transcriber]) != .installed,
                   let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.prepareToAnalyze(in: format)
                let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(200))
                let consumer = Task {
                    var confirmed = ""
                    var provisional = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            confirmed += text
                            if confirmed.count > 1_000 { confirmed = String(confirmed.suffix(1_000)) }
                            provisional = ""
                        } else {
                            provisional = text
                        }
                        onUpdate(confirmed + provisional)
                    }
                }
                do {
                    try await analyzer.start(inputSequence: inputs)
                    var converter: AVAudioConverter?
                    for await frame in frames {
                        let source = frame.buffer
                        if converter == nil { converter = AVAudioConverter(from: source.format, to: format) }
                        guard let converter else { continue }
                        let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate /
                                                         source.format.sampleRate + 1024)
                        guard let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
                        let feed = MeetingOneShotInput(source)
                        var conversionError: NSError?
                        let status = converter.convert(to: target, error: &conversionError) { _, inputStatus in
                            feed.next(inputStatus)
                        }
                        if let conversionError { throw conversionError }
                        if status == .error { throw MeetingError.unavailable("Live audio conversion failed") }
                        if target.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: target)) }
                    }
                    continuation.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await consumer.value
                } catch {
                    continuation.finish()
                    consumer.cancel()
                }
            } catch { /* Final file transcription still runs after recording. */ }
        }
    }
}

private final class MeetingOneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else { status.pointee = .noDataNow; return nil }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
