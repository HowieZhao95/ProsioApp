import AVFoundation
import Foundation
import FluidAudio
import Speech

public struct MeetingSegment: Sendable, Codable {
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: String?
    public let source: String
}

public struct MeetingLocalResult: Sendable {
    public let segments: [MeetingSegment]
    public let warnings: [String]
}

/// A separate final-only Apple pass avoids treating progressive captions as final text.
/// Each track is transcribed independently, so remote speech is retained even when
/// the microphone has acoustic echo of the call.
public struct MeetingProcessor {
    public init() {}

    public func process(_ files: MeetingAudioFiles, locale: Locale) async -> MeetingLocalResult {
        var all: [MeetingSegment] = []
        var warnings: [String] = []
        if let warning = files.warning { warnings.append(warning) }
        let tracks: [(URL, String, Double)] = [
            (files.microphone, "麦克风", files.microphoneOffset),
        ] + (files.system.map { [($0, "系统声音", files.systemOffset ?? 0)] } ?? [])
        let diarizer = OfflineDiarizerManager()
        var diarizerReady = true
        do { try await diarizer.prepareModels() }
        catch {
            diarizerReady = false
            warnings.append("说话人模型暂不可用：\(error.localizedDescription)")
        }
        for (url, source, offset) in tracks {
            do {
                let words = try await Self.transcribe(url, locale: locale)
                let speakers: [SpeakerInterval]
                do {
                    guard diarizerReady else { throw MeetingError.unavailable("model unavailable") }
                    let audio = try AVAudioFile(forReading: url)
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    guard duration <= 45 * 60 else {
                        throw MeetingError.unavailable("录音超过 45 分钟；为避免离线模型占用过多内存，保留文字并跳过说话人分析")
                    }
                    let result = try await diarizer.process(url)
                    speakers = result.segments.map {
                        SpeakerInterval(start: Double($0.startTimeSeconds),
                                        end: Double($0.endTimeSeconds),
                                        name: "\(source)-\($0.speakerId)")
                    }
                } catch {
                    speakers = []
                    if diarizerReady { warnings.append("\(source)说话人分析失败：\(error.localizedDescription)") }
                }
                all += words.map { word in
                    MeetingSegment(start: max(0, word.start + offset), end: max(0, word.end + offset),
                                   text: word.text, speaker: Self.speaker(for: word, in: speakers), source: source)
                }
            } catch {
                warnings.append("\(source)转写失败：\(error.localizedDescription)")
            }
        }
        let ordered = all.sorted { $0.start < $1.start }
        // A speaker played through room speakers may be recognized in both tracks.
        // Remove only strong time-and-text matches; ambiguous cases stay visible.
        let deduplicated = ordered.filter { candidate in
            guard candidate.source == "麦克风" else { return true }
            let normalized = Self.normalized(candidate.text)
            guard normalized.count >= 4 else { return true }
            return !ordered.contains { other in
                guard other.source == "系统声音" else { return false }
                let overlap = max(0, min(candidate.end, other.end) - max(candidate.start, other.start))
                let duration = max(0.001, min(candidate.end - candidate.start, other.end - other.start))
                guard overlap / duration >= 0.5 else { return false }
                let comparison = Self.normalized(other.text)
                let shorter = min(comparison.count, normalized.count)
                let longer = max(comparison.count, normalized.count)
                return shorter * 5 >= longer * 4 &&
                    (comparison.contains(normalized) || normalized.contains(comparison))
            }
        }
        return MeetingLocalResult(segments: deduplicated, warnings: warnings)
    }

    private static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    private struct Word: Sendable { let start: Double; let end: Double; let text: String }
    private struct SpeakerInterval { let start: Double; let end: Double; let name: String }

    private static func speaker(for word: Word, in spans: [SpeakerInterval]) -> String? {
        var scores: [String: Double] = [:]
        for span in spans {
            let overlap = max(0, min(word.end, span.end) - max(word.start, span.start))
            if overlap > 0 { scores[span.name, default: 0] += overlap }
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let first = ranked.first,
              first.value >= max(0.001, word.end - word.start) * 0.5,
              ranked.count == 1 || first.value >= ranked[1].value * 1.25 else { return nil }
        return first.key
    }

    private static func transcribe(_ fileURL: URL, locale: Locale) async throws -> [Word] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw MeetingError.unavailable("SpeechTranscriber does not support \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedTranscriptionWithAlternatives)
        try await AssetInventory.reserve(locale: supported)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: break
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw MeetingError.unavailable("Apple speech assets unavailable")
            }
            try await request.downloadAndInstall()
        case .unsupported:
            throw MeetingError.unavailable("Apple speech assets unsupported")
        @unknown default:
            throw MeetingError.unavailable("Unknown Apple speech asset status")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        let collector = Task<[Word], Error> {
            var output: [Word] = []
            for try await result in transcriber.results where result.isFinal {
                output.append(Word(start: max(0, result.range.start.seconds),
                                   end: max(0, result.range.end.seconds),
                                   text: String(result.text.characters)))
            }
            return output
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }
}
