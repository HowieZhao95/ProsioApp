import Foundation

/// Everything captured about one dictation session for offline diagnosis. Not part of the public
/// contract — written to `session.json` alongside `audio.wav` when `AppSettings.saveDebugRecordings`
/// is on.
struct DebugSessionRecord: Codable, Sendable {
    struct Timings: Codable, Sendable {
        /// `start()` called -> `audio.start()` returned.
        var startToMicOpenMs: Double?
        /// Mic open -> first audio chunk delivered.
        var micOpenToFirstChunkMs: Double?
        /// First audio chunk -> first local (on-device) partial.
        var firstChunkToFirstLocalPartialMs: Double?
        /// `stop()` called -> the final-determining engine's `.final` received (cloud in
        /// `.auto`/`.cloud`, local in `.local`).
        var stopToFinalReceivedMs: Double?
        /// Final received -> insertion finished.
        var finalReceivedToInsertionDoneMs: Double?
    }

    var sessionID: String
    var createdAt: Date
    var mode: String
    var localEngineID: String
    var cloudEngineID: String
    /// The engine whose text actually got used (inserted), if any.
    var engineIDUsed: String?
    var localFinalText: String?
    var cloudFinalText: String?
    var insertedText: String?
    /// `InsertionOutcome.rawValue` on success, or a description of the failure.
    var outcome: String?
    var audioDurationSeconds: Double
    var suspectedDrop: Bool
    var timings: Timings

    /// P1.2: `CloudTranscript.source` ("local" | "cloud"), or "offline-fallback" when
    /// `/api/transcribe` itself was unreachable/timed out and the local transcript was used as-is.
    var routeSource: String? = nil
    /// P1.2: `CloudTranscript.route?.cleanProbability`.
    var routeCleanProbability: Double? = nil
    /// P1.2: `CloudTranscript.route?.reason`.
    var routeReason: String? = nil
    /// P1.2: `PreparedAudio.originalSeconds` (`AudioPreparing.prepare`).
    var originalSeconds: Double? = nil
    /// P1.2: `PreparedAudio.trimmedSeconds`.
    var trimmedSeconds: Double? = nil
    /// P1.2: the uploaded payload's byte count (post trim/encode).
    var uploadBytes: Int? = nil
    /// P1.2: `UploadAudioFormat.rawValue` ("wav" | "ogg-opus") actually uploaded (post any 415->WAV retry).
    var audioFormat: String? = nil

    /// P1: `DictationIntent.rawValue` ("dictate"/"edit"/"ask").
    var intent: String? = nil
    /// P1: `WritingScene.rawValue`.
    var scene: String? = nil
    /// P1: `ComposeRequest.Mode.rawValue` ("rewrite"/"translate"/"edit"/"ask"), if compose ran.
    var composeMode: String? = nil
    var composeLatencyMs: Double? = nil
    /// P1: compose's raw output, distinct from `insertedText` (e.g. a failed rewrite still
    /// inserts the untransformed transcript, but `composeOutput` stays nil).
    var composeOutput: String? = nil

    /// P1.2: the session's intent decision (dictate/edit/ask/translate) — the server's inline
    /// `/api/transcribe` response field, or the client-side `IntentRules` fallback.
    var intentDecisionClassified: String? = nil
    /// "jev" (server) or "rules" (client-side `IntentRules` fallback).
    var intentDecisionSource: String? = nil
    var intentDecisionConfidence: Double? = nil
}

/// Writes debug recordings to disk off the main actor, and prunes old sessions. Not part of the
/// public contract.
enum DebugRecordingWriter {
    /// - Parameters:
    ///   - root: directory debug sessions are written under; created if missing.
    ///   - pcm16: the exact little-endian PCM16 mono samples sent to the engines, concatenated.
    static func write(root: URL, sessionID: UUID, record: DebugSessionRecord, pcm16: Data, sampleRate: Double, keepLast: Int = 30) {
        let fileManager = FileManager.default
        let sessionDir = root.appendingPathComponent("\(isoTimestamp(for: record.createdAt))-\(sessionID.uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let wavData = WAVFile.make(pcm16: pcm16, sampleRate: sampleRate)
            try wavData.write(to: sessionDir.appendingPathComponent("audio.wav"))
            let jsonData = try makeEncoder().encode(record)
            try jsonData.write(to: sessionDir.appendingPathComponent("session.json"))
        } catch {
            // Best-effort diagnostics aid — a write failure must never affect the app.
            DictationLog.logger.error("failed to write debug recording: \(String(describing: error), privacy: .public)")
        }

        pruneOldSessions(in: root, keepLast: keepLast)
    }

    private static func pruneOldSessions(in root: URL, keepLast: Int) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        // Session directory names are `<ISO-timestamp>-<uuid>`, so lexical order == chronological order.
        let sessionDirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard sessionDirs.count > keepLast else { return }
        for dir in sessionDirs.prefix(sessionDirs.count - keepLast) {
            try? fileManager.removeItem(at: dir)
        }
    }

    private static func isoTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        // Colons are legal on APFS but awkward to work with in a terminal/Finder; swap them out.
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
