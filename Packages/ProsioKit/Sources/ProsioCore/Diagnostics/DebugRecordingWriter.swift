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

    /// Only set for `.auto` sessions that went through routing (a router was configured).
    var routeNeedsCloud: Bool? = nil
    var routeCleanProbability: Double? = nil
    var routeReason: String? = nil
    var routeLatencyMs: Double? = nil

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

    /// P1.1: the classifier/rules decision for this session (dictate/edit/ask/translate).
    var intentDecisionClassified: String? = nil
    /// "jev" (server classifier) or "rules" (client-side `IntentRules` fallback).
    var intentDecisionSource: String? = nil
    var intentDecisionConfidence: Double? = nil
    var intentDecisionLatencyMs: Double? = nil
    /// "local" | "final" — which of the two decisions below actually determined this session's
    /// route (mirrors `intentDecisionClassified`/`intentDecisionSource`/etc. above).
    var intentDecisionClassifiedOn: String? = nil
    /// The stop()-time speculative decision made on the local preview, if one ran — kept even when
    /// superseded by a final-transcript reclassification, so a mismatch (e.g. cloud SMART
    /// normalizing a cue word away) is visible in the recording.
    var intentDecisionLocalClassified: String? = nil
    var intentDecisionLocalSource: String? = nil
    var intentDecisionLocalConfidence: Double? = nil
    var intentDecisionLocalLatencyMs: Double? = nil
    /// The final-transcript (re)classification, if one ran (local preview was empty/too short, its
    /// leading text diverged from the final transcript, or the local decision was a rules fallback
    /// — which always reclassifies on the final transcript).
    var intentDecisionFinalClassified: String? = nil
    var intentDecisionFinalSource: String? = nil
    var intentDecisionFinalConfidence: Double? = nil
    var intentDecisionFinalLatencyMs: Double? = nil
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
