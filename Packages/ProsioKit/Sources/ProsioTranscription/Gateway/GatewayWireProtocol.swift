import Foundation
import ProsioCore

// Encoding/decoding for the Gateway transcription-stream envelope. See docs/gateway-ws-protocol.md
// for the full protocol writeup and source citations; this file is the Swift mirror of
// `@ai-sdk/provider-utils`'s `transcription-stream-envelope.ts`.

enum GatewayWireProtocol {
    static let startFrameType = "transcription-stream.start"
    static let audioDoneFrameType = "transcription-stream.audio-done"

    /// Builds the client's `transcription-stream.start` TEXT frame.
    ///
    /// `providerOptions.google` is populated from `TranscriptionOptions`:
    /// - `.smart` → `"mode": "SMART"`; `.verbatim` → omitted (provider default).
    /// - non-empty `vocabulary` → `customVocabulary`.
    /// - non-empty `languageHints` → `languageCodes`.
    /// The `google` object itself is omitted when there is nothing to say.
    static func startFrame(sampleRate: Double, options: TranscriptionOptions) throws -> String {
        var googleOptions: [String: Any] = [:]
        if options.mode == .smart {
            googleOptions["mode"] = "SMART"
        }
        if !options.vocabulary.isEmpty {
            googleOptions["customVocabulary"] = options.vocabulary
        }
        if !options.languageHints.isEmpty {
            googleOptions["languageCodes"] = options.languageHints
        }

        var frame: [String: Any] = [
            "type": startFrameType,
            "inputAudioFormat": [
                "type": "audio/pcm",
                "rate": sampleRate,
            ],
        ]
        if !googleOptions.isEmpty {
            frame["providerOptions"] = ["google": googleOptions]
        }

        guard JSONSerialization.isValidJSONObject(frame) else {
            throw ProsioError.transcriptionFailed("failed to encode start frame")
        }
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProsioError.transcriptionFailed("failed to encode start frame")
        }
        return text
    }

    /// The client's `transcription-stream.audio-done` TEXT frame (fixed content).
    static let audioDoneFrame = "{\"type\":\"\(audioDoneFrameType)\"}"
}

/// A decoded server → client stream part. Only the fields we act on are extracted; unknown
/// `type`s decode to `.unknown` per envelope rule 6 (forward compatibility), and known types with
/// missing/malformed required fields decode to `nil` (malformed frame, ignored).
enum GatewayServerPart: Sendable, Equatable {
    case streamStart
    case transcriptDelta(delta: String)
    case transcriptPartial(text: String)
    case transcriptFinal(text: String)
    case finish(text: String)
    case responseMetadata
    case raw
    case error(message: String)
    case unknown

    static func decode(_ text: String) -> GatewayServerPart? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "stream-start":
            return .streamStart

        case "transcript-delta":
            guard let delta = json["delta"] as? String else { return nil }
            return .transcriptDelta(delta: delta)

        case "transcript-partial":
            guard let text = json["text"] as? String else { return nil }
            return .transcriptPartial(text: text)

        case "transcript-final":
            guard let text = json["text"] as? String else { return nil }
            return .transcriptFinal(text: text)

        case "finish":
            guard let text = json["text"] as? String else { return nil }
            return .finish(text: text)

        case "response-metadata":
            return .responseMetadata

        case "raw":
            return .raw

        case "error":
            let message = errorMessage(from: json["error"])
            return .error(message: message)

        default:
            return .unknown
        }
    }

    private static func errorMessage(from payload: Any?) -> String {
        if let dict = payload as? [String: Any], let message = dict["message"] as? String {
            return message
        }
        if let message = payload as? String {
            return message
        }
        return "unknown gateway error"
    }
}
