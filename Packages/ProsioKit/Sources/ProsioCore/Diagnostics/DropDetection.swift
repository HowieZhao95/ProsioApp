import Foundation

/// Heuristic for flagging a likely-truncated cloud transcript, by comparing it against the
/// on-device (local) transcript of the same audio. Not part of the public contract.
enum DropDetection {
    /// True when `cloudText` looks suspiciously short next to `localText` — i.e. cloud may have
    /// dropped content. Compares character counts after stripping whitespace/punctuation, and
    /// only fires when `localText` itself is long enough to make the comparison meaningful.
    static func isSuspectedDrop(localText: String?, cloudText: String?, minLocalLength: Int = 12, ratioThreshold: Double = 0.55) -> Bool {
        guard let localText, let cloudText else { return false }
        let strippedLocal = strip(localText)
        let strippedCloud = strip(cloudText)
        guard strippedLocal.count >= minLocalLength else { return false }
        return Double(strippedCloud.count) < ratioThreshold * Double(strippedLocal.count)
    }

    private static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.punctuationCharacters.contains(scalar)
        }))
    }
}
