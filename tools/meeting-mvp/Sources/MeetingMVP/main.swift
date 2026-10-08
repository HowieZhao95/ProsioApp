import AVFoundation
import Foundation
import FluidAudio
import ScreenCaptureKit
import Speech

struct Utterance: Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

struct SpeakerSpan: Codable, Sendable {
    let start: Double
    let end: Double
    let speaker: String
}

struct Report: Codable, Sendable {
    let input: String
    let locale: String
    let apple: [Utterance]
    let fluidAudio: [SpeakerSpan]
    let soniox: SonioxTranscript?
    let cloudError: String?
    let timings: [String: Double]
}

struct SonioxTranscript: Codable, Sendable {
    struct Token: Codable, Sendable {
        let text: String
        let start_ms: Double?
        let end_ms: Double?
        let speaker: String?
        let language: String?
    }
    let text: String
    let tokens: [Token]
}

private final class OneShotAudioInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

enum MVPError: Error, CustomStringConvertible {
    case usage(String)
    case unsupportedLocale(String)
    case unavailable(String)
    case cloud(String)

    var description: String {
        switch self {
        case .usage(let message), .unsupportedLocale(let message),
             .unavailable(let message), .cloud(let message): message
        }
    }
}

@main
struct MeetingMVP {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("MeetingMVP: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw MVPError.usage(usage) }
        args.removeFirst()
        switch command {
        case "analyze":
            let input = try value("--input", in: args)
            let locale = optionalValue("--locale", in: args) ?? "en-US"
            let output = optionalValue("--output", in: args) ?? "meeting-report.json"
            let cloud = args.contains("--soniox")
            try await analyze(input: URL(fileURLWithPath: input), locale: locale,
                              output: URL(fileURLWithPath: output), cloud: cloud,
                              skipApple: args.contains("--skip-apple"),
                              skipFluid: args.contains("--skip-fluid"))
        case "record-mic":
            let output = try value("--output", in: args)
            let seconds = Double(try value("--seconds", in: args)) ?? 0
            guard seconds > 0, seconds <= 3600 else {
                throw MVPError.usage("--seconds must be 1...3600")
            }
            try await recordMicrophone(to: URL(fileURLWithPath: output), seconds: seconds)
        case "record-system":
            let output = try value("--output", in: args)
            let seconds = Double(try value("--seconds", in: args)) ?? 0
            guard seconds > 0, seconds <= 3600 else {
                throw MVPError.usage("--seconds must be 1...3600")
            }
            try await SystemAudioRecorder.record(
                to: URL(fileURLWithPath: output), seconds: seconds)
        case "replay-live":
            let input = try value("--input", in: args)
            let locale = optionalValue("--locale", in: args) ?? "en-US"
            try await replayLive(input: URL(fileURLWithPath: input), locale: locale)
        default:
            throw MVPError.usage(usage)
        }
    }

    static let usage = """
    Usage:
      MeetingMVP analyze --input meeting.wav [--locale en-US] [--output report.json] [--soniox]
                         [--skip-apple] [--skip-fluid]
      MeetingMVP record-mic --seconds 30 --output microphone.caf
      MeetingMVP record-system --seconds 30 --output system.m4a
      MeetingMVP replay-live --input meeting.wav [--locale en-US]
    --soniox sends audio to Soniox and incurs API cost. It requires SONIOX_API_KEY.
    """

    static func value(_ key: String, in args: [String]) throws -> String {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
            throw MVPError.usage("Missing \(key)\n\(usage)")
        }
        return args[index + 1]
    }

    static func optionalValue(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func analyze(input: URL, locale: String, output: URL, cloud: Bool,
                        skipApple: Bool, skipFluid: Bool) async throws {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw MVPError.unavailable("Input file does not exist: \(input.path)")
        }
        let totalStart = Date()
        var apple: [Utterance] = []
        var appleSeconds = 0.0
        if !skipApple {
            print("Apple SpeechTranscriber: \(locale)")
            let appleStart = Date()
            apple = try await transcribeWithApple(input, locale: locale)
            appleSeconds = Date().timeIntervalSince(appleStart)
            print("Apple: \(apple.count) segments in \(String(format: "%.2f", appleSeconds))s")
        }

        var spans: [SpeakerSpan] = []
        var fluidSeconds = 0.0
        if !skipFluid {
            print("FluidAudio: preparing offline diarizer")
            let fluidStart = Date()
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
            let result = try await manager.process(input)
            spans = result.segments.map {
                SpeakerSpan(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
            }
            fluidSeconds = Date().timeIntervalSince(fluidStart)
            print("FluidAudio: \(spans.count) speaker spans in \(String(format: "%.2f", fluidSeconds))s")
        }

        var soniox: SonioxTranscript?
        var cloudError: String?
        var cloudSeconds = 0.0
        if cloud {
            let key = ProcessInfo.processInfo.environment["SONIOX_API_KEY"] ?? ""
            if key.isEmpty {
                cloudError = "SONIOX_API_KEY is not set"
            } else {
                let cloudStart = Date()
                do {
                    soniox = try await SonioxClient(apiKey: key).transcribe(file: input, locale: locale)
                    print("Soniox: \(soniox?.tokens.count ?? 0) tokens")
                } catch {
                    cloudError = String(describing: error)
                    fputs("Soniox unavailable; local report remains usable: \(error)\n", stderr)
                }
                cloudSeconds = Date().timeIntervalSince(cloudStart)
            }
        }

        let attributedApple = apple.map { attribute($0, with: spans) }
        let report = Report(
            input: input.path, locale: locale, apple: attributedApple, fluidAudio: spans,
            soniox: soniox, cloudError: cloudError,
            timings: ["appleSeconds": appleSeconds, "fluidAudioSeconds": fluidSeconds,
                      "sonioxSeconds": cloudSeconds, "totalSeconds": Date().timeIntervalSince(totalStart)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        print("Saved: \(output.path)")
    }

    static func attribute(_ utterance: Utterance, with spans: [SpeakerSpan]) -> Utterance {
        var durations: [String: Double] = [:]
        for span in spans {
            let overlap = max(0, min(utterance.end, span.end) - max(utterance.start, span.start))
            if overlap > 0 { durations[span.speaker, default: 0] += overlap }
        }
        let ranked = durations.sorted { $0.value > $1.value }
        let duration = max(0.001, utterance.end - utterance.start)
        guard let best = ranked.first, best.value / duration >= 0.5,
              ranked.count == 1 || best.value >= ranked[1].value * 1.25 else {
            return utterance
        }
        return Utterance(start: utterance.start, end: utterance.end,
                         text: utterance.text, speaker: best.key)
    }

    static func transcribeWithApple(_ input: URL, locale: String) async throws -> [Utterance] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw MVPError.unsupportedLocale("SpeechTranscriber does not support \(locale)")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedTranscriptionWithAlternatives)
        try await AssetInventory.reserve(locale: supported)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: break
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw MVPError.unavailable("No Apple asset installation request")
            }
            print("Apple model installation: \(request.progress.localizedDescription ?? "starting")")
            try await request.downloadAndInstall()
        case .unsupported:
            throw MVPError.unsupportedLocale("Apple assets unsupported for \(locale)")
        @unknown default:
            throw MVPError.unavailable("Unknown Apple asset status")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: input)
        let collector = Task<[Utterance], Error> {
            var output: [Utterance] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let utterance = Utterance(
                    start: max(0, result.range.start.seconds),
                    end: max(0, result.range.end.seconds),
                    text: String(result.text.characters), speaker: nil
                )
                output.append(utterance)
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

    static func replayLive(input: URL, locale: String) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw MVPError.unsupportedLocale("SpeechTranscriber does not support \(locale)")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
        try await AssetInventory.reserve(locale: supported)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MVPError.unavailable("No compatible Apple analyzer format")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: targetFormat)
        let (audio, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let began = Date()
        let collector = Task<(Int, Double), Error> {
            var count = 0
            var first = -1.0
            for try await result in transcriber.results {
                let elapsed = Date().timeIntervalSince(began)
                if first < 0 { first = elapsed }
                count += 1
                print(String(format: "live +%.2fs [%.2f–%.2f] %@", elapsed,
                             result.range.start.seconds, result.range.end.seconds,
                             String(result.text.characters)))
            }
            return (count, first)
        }
        do {
            try await analyzer.start(inputSequence: audio)
            let file = try AVAudioFile(forReading: input)
            let sourceFormat = file.processingFormat
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw MVPError.unavailable("Audio converter unavailable")
            }
            let framesPerChunk = AVAudioFrameCount(max(1, Int(sourceFormat.sampleRate * 0.25)))
            while file.framePosition < file.length {
                guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesPerChunk) else {
                    throw MVPError.unavailable("Unable to allocate audio buffer")
                }
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                try file.read(into: source, frameCount: min(framesPerChunk, remaining))
                if source.frameLength == 0 { break }
                let capacity = AVAudioFrameCount(Double(source.frameLength) * targetFormat.sampleRate
                                                 / sourceFormat.sampleRate + 1024)
                guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    throw MVPError.unavailable("Unable to allocate converted audio buffer")
                }
                let feed = OneShotAudioInput(source)
                var conversionError: NSError?
                let conversion = converter.convert(to: target, error: &conversionError) { _, status in
                    feed.next(status)
                }
                if let conversionError { throw conversionError }
                if conversion == .error { throw MVPError.unavailable("Audio conversion failed") }
                if target.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: target)) }
                try await Task.sleep(for: .seconds(Double(source.frameLength) / sourceFormat.sampleRate))
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let (count, first) = try await collector.value
            print(String(format: "Live replay: %d updates, first update at %.2fs", count, first))
        } catch {
            continuation.finish()
            collector.cancel()
            throw error
        }
    }

    static func recordMicrophone(to output: URL, seconds: Double) async throws {
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else { throw MVPError.unavailable("Microphone permission denied") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            do { try file.write(from: buffer) }
            catch { fputs("write error: \(error)\n", stderr) }
        }
        defer { input.removeTap(onBus: 0); engine.stop() }
        try engine.start()
        print("Recording microphone for \(seconds)s → \(output.path)")
        try await Task.sleep(for: .seconds(seconds))
        print("Recording complete")
    }
}

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.prosio.meeting-mvp.system-audio")
    private var started = false
    private var buffers = 0
    private var appendError: String?

    private init(output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ])
        writerInput.expectsMediaDataInRealTime = true
        writer.add(writerInput)
        super.init()
    }

    static func record(to output: URL, seconds: Double) async throws {
        let recorder = try SystemAudioRecorder(output: output)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MVPError.unavailable("No display available for system audio capture")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        recorder.stream = stream
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        print("Recording system audio for \(seconds)s → \(output.path)")
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        recorder.queue.sync { recorder.writerInput.markAsFinished() }
        await recorder.writer.finishWriting()
        if let error = recorder.appendError ?? recorder.writer.error?.localizedDescription {
            throw MVPError.unavailable("System audio recording failed: \(error)")
        }
        guard recorder.buffers > 0 else {
            throw MVPError.unavailable("No system audio buffers arrived (check permission and playback)")
        }
        print("System audio complete: \(recorder.buffers) buffers")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        if !started {
            guard writer.startWriting() else {
                appendError = writer.error?.localizedDescription ?? "AVAssetWriter.startWriting failed"
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if writerInput.isReadyForMoreMediaData {
            if writerInput.append(sampleBuffer) { buffers += 1 }
            else { appendError = writer.error?.localizedDescription ?? "audio append failed" }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.appendError = error.localizedDescription }
    }
}

struct SonioxClient: Sendable {
    let apiKey: String
    private let base = URL(string: "https://api.soniox.com/v1")!

    func transcribe(file: URL, locale: String) async throws -> SonioxTranscript {
        let boundary = "meeting-mvp-\(UUID().uuidString)"
        let multipart = FileManager.default.temporaryDirectory.appending(path: "soniox-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: multipart) }
        FileManager.default.createFile(atPath: multipart.path, contents: nil)
        let writer = try FileHandle(forWritingTo: multipart)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try writer.close()

        var upload = request("/files", method: "POST")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (uploaded, uploadResponse) = try await URLSession.shared.upload(for: upload, fromFile: multipart)
        let fileID = try id(from: uploaded, response: uploadResponse)
        var transcriptionID: String?
        do {
            let hints = locale.split(separator: "-").first.map(String.init).map { [$0] } ?? []
            let config: [String: Any] = [
                "model": "stt-async-v5", "file_id": fileID,
                "enable_speaker_diarization": true,
                "enable_language_identification": true,
                "language_hints": hints,
                "client_reference_id": "meeting-mvp-\(UUID().uuidString)"
            ]
            var create = request("/transcriptions", method: "POST")
            create.setValue("application/json", forHTTPHeaderField: "Content-Type")
            create.httpBody = try JSONSerialization.data(withJSONObject: config)
            let created = try await data(create)
            let jobID = try id(from: created, response: nil)
            transcriptionID = jobID

            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                let statusData = try await data(request("/transcriptions/\(jobID)"))
                guard let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                      let state = status["status"] as? String else { throw MVPError.cloud("Invalid Soniox status") }
                if state == "completed" {
                    let transcriptData = try await data(request("/transcriptions/\(jobID)/transcript"))
                    let transcript = try JSONDecoder().decode(SonioxTranscript.self, from: transcriptData)
                    await cleanup(fileID: fileID, transcriptionID: transcriptionID)
                    return transcript
                }
                if state == "error" || state == "failed" {
                    throw MVPError.cloud("Soniox job failed: \(status["error_message"] ?? state)")
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw MVPError.cloud("Soniox job timed out; task ID \(jobID)")
        } catch {
            await cleanup(fileID: fileID, transcriptionID: transcriptionID)
            throw error
        }
    }

    private func cleanup(fileID: String, transcriptionID: String?) async {
        if let transcriptionID { try? await delete("/transcriptions/\(transcriptionID)") }
        try? await delete("/files/\(fileID)")
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var value = URLRequest(url: base.appending(path: path))
        value.httpMethod = method
        value.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        value.timeoutInterval = 120
        return value
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let (body, response) = try await URLSession.shared.data(for: request)
        try validate(body, response: response)
        return body
    }

    private func delete(_ path: String) async throws {
        _ = try await data(request(path, method: "DELETE"))
    }

    private func id(from body: Data, response: URLResponse?) throws -> String {
        if let response { try validate(body, response: response) }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String else { throw MVPError.cloud("Soniox response missing ID") }
        return id
    }

    private func validate(_ body: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MVPError.cloud("Soniox HTTP \(code): \(String(decoding: body.prefix(800), as: UTF8.self))")
        }
    }
}
