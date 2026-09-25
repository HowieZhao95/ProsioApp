import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Encoding/decoding tests against the envelope documented in docs/gateway-ws-protocol.md,
/// mirroring `@ai-sdk/provider-utils`'s `transcription-stream-envelope.ts`.
@Suite struct GatewayWireProtocolTests {

    // MARK: - Start frame encoding

    @Test func startFrame_smartModeWithVocabularyAndLanguageHints() throws {
        let options = TranscriptionOptions(mode: .smart, vocabulary: ["Prosio", "Kubernetes"], languageHints: ["zh-CN", "en-US"])
        let text = try GatewayWireProtocol.startFrame(sampleRate: 16_000, options: options)
        let json = try decodeJSONObject(text)

        #expect(json["type"] as? String == "transcription-stream.start")
        let inputAudioFormat = try #require(json["inputAudioFormat"] as? [String: Any])
        #expect(inputAudioFormat["type"] as? String == "audio/pcm")
        #expect(inputAudioFormat["rate"] as? Double == 16_000)

        let providerOptions = try #require(json["providerOptions"] as? [String: Any])
        let google = try #require(providerOptions["google"] as? [String: Any])
        #expect(google["mode"] as? String == "SMART")
        #expect(google["customVocabulary"] as? [String] == ["Prosio", "Kubernetes"])
        #expect(google["languageCodes"] as? [String] == ["zh-CN", "en-US"])
    }

    @Test func startFrame_verbatimModeNoExtras_omitsGoogleKey() throws {
        let options = TranscriptionOptions(mode: .verbatim, vocabulary: [], languageHints: [])
        let text = try GatewayWireProtocol.startFrame(sampleRate: 16_000, options: options)
        let json = try decodeJSONObject(text)

        #expect(json["providerOptions"] == nil)
        let inputAudioFormat = try #require(json["inputAudioFormat"] as? [String: Any])
        #expect(inputAudioFormat["rate"] as? Double == 16_000)
    }

    @Test func audioDoneFrame_isFixedEnvelope() throws {
        let json = try decodeJSONObject(GatewayWireProtocol.audioDoneFrame)
        #expect(json["type"] as? String == "transcription-stream.audio-done")
    }

    // MARK: - Server part decoding (fixtures from docs/gateway-ws-protocol.md §4c)

    @Test func decode_streamStart() throws {
        let part = GatewayServerPart.decode(#"{"type":"stream-start","warnings":[]}"#)
        #expect(part == .streamStart)
    }

    @Test func decode_transcriptDelta() throws {
        let part = GatewayServerPart.decode(#"{"type":"transcript-delta","delta":"hello "}"#)
        #expect(part == .transcriptDelta(delta: "hello "))
    }

    @Test func decode_transcriptPartial() throws {
        let part = GatewayServerPart.decode(#"{"type":"transcript-partial","text":"hello world","startSecond":0.0,"durationInSeconds":1.2}"#)
        #expect(part == .transcriptPartial(text: "hello world"))
    }

    @Test func decode_transcriptFinal() throws {
        let part = GatewayServerPart.decode(#"{"type":"transcript-final","text":"hello world.","startSecond":0.0,"endSecond":1.2}"#)
        #expect(part == .transcriptFinal(text: "hello world."))
    }

    @Test func decode_finish() throws {
        let part = GatewayServerPart.decode(#"{"type":"finish","text":"hello world.","segments":[],"language":"en"}"#)
        #expect(part == .finish(text: "hello world."))
    }

    @Test func decode_error_objectPayload() throws {
        let part = GatewayServerPart.decode(#"{"type":"error","error":{"message":"boom","type":"invalid_request_error"}}"#)
        #expect(part == .error(message: "boom"))
    }

    @Test func decode_error_stringPayload() throws {
        let part = GatewayServerPart.decode(#"{"type":"error","error":"boom"}"#)
        #expect(part == .error(message: "boom"))
    }

    @Test func decode_unknownType_isUnknownNotNil() throws {
        // Envelope rule 6: unknown types must be ignored, not treated as malformed.
        let part = GatewayServerPart.decode(#"{"type":"some-future-part","stuff":1}"#)
        #expect(part == .unknown)
    }

    @Test func decode_malformedJSON_returnsNil() throws {
        #expect(GatewayServerPart.decode("not json") == nil)
    }

    @Test func decode_missingRequiredField_returnsNil() throws {
        // `transcript-delta` requires `delta`.
        #expect(GatewayServerPart.decode(#"{"type":"transcript-delta"}"#) == nil)
    }

    @Test func decode_responseMetadataAndRaw_areIgnorableNotNil() throws {
        #expect(GatewayServerPart.decode(#"{"type":"response-metadata","modelId":"x"}"#) == .responseMetadata)
        #expect(GatewayServerPart.decode(#"{"type":"raw","rawValue":{}}"#) == .raw)
    }

    private func decodeJSONObject(_ text: String) throws -> [String: Any] {
        let data = try #require(text.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
