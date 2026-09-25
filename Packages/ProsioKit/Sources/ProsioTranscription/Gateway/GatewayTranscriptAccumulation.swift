import Foundation

// Accumulation model for the Gateway's per-segment stream parts, derived from a live run against
// the real Gateway (2026-09-26): the server emits `transcript-partial` (raw in-progress text for
// the CURRENT segment, replacing the previous partial within that segment), then exactly one
// `transcript-delta` per segment (the SMART-cleaned, COMMITTED text for that whole segment — it
// supersedes the segment's partials, not an incremental append fragment), then a new segment's
// partials start fresh. `transcript-final` may also appear with a fuller text near the end, and
// `finish` is still the authoritative terminal event per the envelope (see
// docs/gateway-ws-protocol.md).
//
// `GatewayServerPart.decode`'s field-level parsing already matches the envelope; this file is
// purely the "what do these mean, and how do they combine into one cumulative preview string"
// layer that the P0 doc got wrong for `transcript-delta` (assumed an appendable fragment).

/// Running transcript state for one Gateway session: `committed` is the sum of every completed
/// segment's `transcript-delta` text so far; `currentPartial` is the live, still-revisable text
/// of whichever segment hasn't produced its `transcript-delta` yet.
struct GatewayTranscriptAccumulator {
    private(set) var committed = ""
    private(set) var currentPartial = ""
    private(set) var lastTranscriptFinalText: String?

    /// `transcript-partial`: replaces the current segment's in-progress text.
    mutating func applyPartial(_ text: String) -> String {
        currentPartial = text
        return cumulative
    }

    /// `transcript-delta`: the finished, SMART-cleaned text for the current segment. Committed
    /// permanently; the segment's partial is cleared since it's now superseded.
    mutating func applyDelta(_ text: String) -> String {
        committed = joinTranscriptSegments(committed, text)
        currentPartial = ""
        return cumulative
    }

    /// `transcript-final`: remembered only as a fallback for the terminal `.final` text, in case
    /// `finish.text` arrives empty (see `resolveFinalText`). Does not affect `cumulative`.
    mutating func applyTranscriptFinal(_ text: String) {
        lastTranscriptFinalText = text
    }

    /// What `.partial` should report right now: every committed segment, plus whatever of the
    /// current segment is in flight.
    var cumulative: String {
        joinTranscriptSegments(committed, currentPartial)
    }

    /// `finish.text` if present/non-empty, else the last `transcript-final` text, else whatever
    /// was committed so far.
    func resolveFinalText(finishText: String) -> String {
        if !finishText.isEmpty { return finishText }
        if let lastTranscriptFinalText, !lastTranscriptFinalText.isEmpty { return lastTranscriptFinalText }
        return committed
    }
}

/// Joins two transcript fragments, inserting a single space only when it looks genuinely needed
/// (both sides end/start with a "word" character and neither side is CJK, which is written
/// without inter-word spaces). Empty operands pass through unchanged. Not linguistically perfect —
/// a heuristic good enough that the SMART-cleaned provider text (which already carries its own
/// punctuation/spacing) doesn't get run together or double-spaced when we stitch segments.
func joinTranscriptSegments(_ a: String, _ b: String) -> String {
    guard !a.isEmpty else { return b }
    guard !b.isEmpty else { return a }
    guard let lastA = a.unicodeScalars.last, let firstB = b.unicodeScalars.first else { return a + b }

    if isCJKScalar(lastA) || isCJKScalar(firstB) { return a + b }
    if CharacterSet.whitespacesAndNewlines.contains(lastA) || CharacterSet.whitespacesAndNewlines.contains(firstB) { return a + b }
    if !CharacterSet.alphanumerics.contains(lastA) || !CharacterSet.alphanumerics.contains(firstB) { return a + b }

    return a + " " + b
}

private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, // Hiragana + Katakana
         0x3400...0x4DBF, // CJK Unified Ideographs Extension A
         0x4E00...0x9FFF, // CJK Unified Ideographs
         0xAC00...0xD7A3, // Hangul syllables
         0xF900...0xFAFF: // CJK Compatibility Ideographs
        return true
    default:
        return false
    }
}
