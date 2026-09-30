import AVFoundation
import CoreMedia
import Foundation

private struct InputDocument: Decodable {
    let completed: Bool?
    let phase: String?
    let sources: [InputSource]?
    let segments: [InputSegment]
    let warnings: [String]?
    let failures: [String]?
}

private struct InputSource: Decodable {
    let id: String
    let kind: String
}

private struct InputSegment: Decodable {
    let id: String?
    let sourceID: String
    let relativePath: String
    let timelineStartMicroseconds: Int64
    let mediaStartMicroseconds: Int64?
    let durationMicroseconds: Int64
    let width: Int?
    let height: Int?
    let sampleRate: Int?
    let channelCount: Int?
}

private struct MediaRange: Codable {
    let startSeconds: Double
    let durationSeconds: Double
    var endSeconds: Double { startSeconds + durationSeconds }
}

private struct TrackAudit: Codable {
    let mediaType: String
    let timeRange: MediaRange?
    let naturalWidth: Double?
    let naturalHeight: Double?
    let encodedWidth: Int?
    let encodedHeight: Int?
    let nominalFrameRate: Float?
    let sampleRate: Double?
    let channelCount: Int?
    let codec: String?
    var rangeToleranceSeconds: Double?
}

private struct SegmentAudit: Codable {
    let id: String?
    let sourceID: String
    let relativePath: String
    let timelineRangeMicroseconds: [Int64]
    let declaredMediaRangeMicroseconds: [Int64]
    let assetDurationSeconds: Double?
    let isPlayable: Bool?
    let tracks: [TrackAudit]
    let status: String
    let issues: [String]
}

private struct TimelineIssue: Codable {
    let previousSegmentID: String?
    let nextSegmentID: String?
    let kind: String
    let deltaMicroseconds: Int64
}

private struct SourceTimelineAudit: Codable {
    let sourceID: String
    let segmentCount: Int
    let firstStartMicroseconds: Int64?
    let lastEndMicroseconds: Int64?
    let timelineIssues: [TimelineIssue]
    let gapCount: Int
    let overlapCount: Int
    let invalidRangeCount: Int
}

private struct AuditReport: Codable {
    let tool: String
    let auditScope: String
    let evidenceLimit: String
    let inputPath: String
    let mediaRoot: String
    let inputKind: String
    let inputCompleted: Bool
    let snapshotIsPartial: Bool
    let segmentCount: Int
    let auditedCount: Int
    let passedCount: Int
    let failedCount: Int
    let noCompletedMedia: Bool
    let informationalGapCount: Int
    let timelineErrorCount: Int
    let inputWarnings: [String]
    let inputFailures: [String]
    let crossSourceSpansMicroseconds: [String: [Int64]]
    let sources: [SourceTimelineAudit]
    let segments: [SegmentAudit]
}

private enum AuditError: LocalizedError {
    case usage
    case input(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: recording-media-audit <progress.json|report.json|recording.json> [media-root]"
        case .input(let message): message
        case .unsafePath(let path): "Unsafe media path (must resolve inside the selected root): \(path)"
        }
    }
}

@main
private struct RecordingMediaAudit {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard (1...2).contains(args.count) else { throw AuditError.usage }
            let inputURL = URL(fileURLWithPath: args[0]).standardizedFileURL
            let rootURL = URL(fileURLWithPath: args.count == 2 ? args[1] : inputURL.deletingLastPathComponent().path,
                              isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let inputData: Data
            do { inputData = try Data(contentsOf: inputURL) }
            catch { throw AuditError.input("Cannot read input JSON: \(error.localizedDescription)") }
            let document: InputDocument
            do { document = try JSONDecoder().decode(InputDocument.self, from: inputData) }
            catch { throw AuditError.input("Input JSON does not contain a supported segments manifest: \(error.localizedDescription)") }

            var audits: [SegmentAudit] = []
            audits.reserveCapacity(document.segments.count)
            for segment in document.segments {
                let kind = document.sources?.first(where: { $0.id == segment.sourceID })?.kind
                audits.append(await audit(segment, root: rootURL,
                                          expectedMediaType: expectedMediaType(sourceID: segment.sourceID, kind: kind)))
            }
            let sources = timelineAudits(document.segments)
            let spans: [String: [Int64]] = Dictionary(grouping: document.segments, by: \.sourceID).mapValues { group -> [Int64] in
                let valid = group.filter { $0.timelineStartMicroseconds >= 0 && $0.durationMicroseconds > 0 && safeEnd($0.timelineStartMicroseconds, $0.durationMicroseconds) != nil }
                let start = valid.map(\.timelineStartMicroseconds).min() ?? 0
                guard let end = valid.compactMap({ safeEnd($0.timelineStartMicroseconds, $0.durationMicroseconds) }).max() else { return [] }
                return [start, end]
            }
            let passed = audits.filter { $0.status == "passed" }.count
            let failed = audits.count - passed
            let gapCount = sources.reduce(0) { $0 + $1.gapCount }
            let timelineErrorCount = sources.reduce(0) { $0 + $1.overlapCount + $1.invalidRangeCount }
            let noCompletedMedia = document.segments.isEmpty
            let completed = document.completed ?? (document.phase == "ready")
            let report = AuditReport(
                tool: "ProsioRecordingMediaAudit/1",
                auditScope: "finalizedMediaMetadata",
                evidenceLimit: "AVFoundation isPlayable and track metadata checks do not decode every frame or prove real-device lip-sync, two-hour drift, or editor import acceptance.",
                inputPath: inputURL.path,
                mediaRoot: rootURL.path,
                inputKind: inputURL.lastPathComponent == "progress.json" ? "progress" : inputURL.lastPathComponent == "report.json" ? "stressReport" : "manifest",
                inputCompleted: completed,
                snapshotIsPartial: !completed,
                segmentCount: document.segments.count,
                auditedCount: audits.count,
                passedCount: passed,
                failedCount: failed,
                noCompletedMedia: noCompletedMedia,
                informationalGapCount: gapCount,
                timelineErrorCount: timelineErrorCount,
                inputWarnings: document.warnings ?? [],
                inputFailures: document.failures ?? [],
                crossSourceSpansMicroseconds: spans,
                sources: sources,
                segments: audits
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = try encoder.encode(report)
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0A]))
            if noCompletedMedia || failed > 0 || timelineErrorCount > 0 || !(document.failures ?? []).isEmpty { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func audit(_ segment: InputSegment, root: URL, expectedMediaType: String?) async -> SegmentAudit {
        let mediaStart = segment.mediaStartMicroseconds ?? 0
        guard let timelineEnd = safeEnd(segment.timelineStartMicroseconds, segment.durationMicroseconds),
              let mediaEnd = safeEnd(mediaStart, segment.durationMicroseconds) else {
            return failed(segment, mediaStart: mediaStart, mediaEnd: mediaStart,
                          issue: "declared time range overflows Int64")
        }
        guard segment.durationMicroseconds > 0,
              segment.timelineStartMicroseconds >= 0,
              mediaStart >= 0,
              mediaEnd >= mediaStart,
              timelineEnd >= segment.timelineStartMicroseconds else {
            return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd, issue: "invalid or overflowing declared time range")
        }
        var issues: [String] = []
        guard let mediaURL = safeMediaURL(segment.relativePath, root: root) else {
            return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd, issue: "unsafe relative path or symlink escapes media root")
        }
        let values = try? mediaURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
            return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd, issue: "missing, empty, or non-regular media file")
        }

        let asset = AVURLAsset(url: mediaURL)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd,
                              issue: "AVFoundation reports the finalized asset as not playable", isPlayable: false)
            }
            let duration = try await asset.load(.duration).seconds
            let assetTracks = try await asset.load(.tracks)
            guard duration.isFinite, duration > 0 else {
                return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd, issue: "asset duration is invalid")
            }
            var tracks: [TrackAudit] = []
            var relevantTracks: [TrackAudit] = []
            for track in assetTracks where track.mediaType == .video || track.mediaType == .audio {
                let auditTrack = try await inspect(track)
                tracks.append(auditTrack)
                relevantTracks.append(auditTrack)
            }
            guard !relevantTracks.isEmpty else {
                return SegmentAudit(id: segment.id, sourceID: segment.sourceID, relativePath: segment.relativePath,
                    timelineRangeMicroseconds: [segment.timelineStartMicroseconds, timelineEnd],
                    declaredMediaRangeMicroseconds: [mediaStart, mediaEnd], assetDurationSeconds: duration,
                    isPlayable: isPlayable, tracks: tracks, status: "failed", issues: ["asset has no audio or video tracks"])
            }
            if let expectedMediaType, !relevantTracks.contains(where: { $0.mediaType == expectedMediaType }) {
                issues.append("source expects a \(expectedMediaType == AVMediaType.video.rawValue ? "video" : "audio") track, but the asset has none")
            }
            let declaredStart = Double(mediaStart) / 1_000_000
            let declaredDuration = Double(segment.durationMicroseconds) / 1_000_000
            for track in relevantTracks {
                guard let range = track.timeRange else {
                    issues.append("\(track.mediaType) track has no valid time range")
                    continue
                }
                let tolerance = track.rangeToleranceSeconds ?? 0.001
                if declaredStart < range.startSeconds - tolerance {
                    issues.append("declared media start precedes \(track.mediaType) range by more than codec tolerance")
                }
                if declaredStart + declaredDuration > range.endSeconds + tolerance {
                    issues.append("declared media end exceeds \(track.mediaType) range by more than codec tolerance")
                }
            }
            let assetTolerance = relevantTracks.compactMap(\.rangeToleranceSeconds).max() ?? 0.001
            if declaredStart + declaredDuration > duration + assetTolerance {
                issues.append("declared media end exceeds asset duration by more than the applicable codec boundary tolerance")
            }
            compareDeclaredMetadata(segment, tracks: relevantTracks, issues: &issues)
            return SegmentAudit(id: segment.id, sourceID: segment.sourceID, relativePath: segment.relativePath,
                timelineRangeMicroseconds: [segment.timelineStartMicroseconds, timelineEnd],
                declaredMediaRangeMicroseconds: [mediaStart, mediaEnd], assetDurationSeconds: duration, isPlayable: isPlayable,
                tracks: tracks, status: issues.isEmpty ? "passed" : "failed", issues: issues)
        } catch {
            return failed(segment, mediaStart: mediaStart, mediaEnd: mediaEnd,
                          issue: "AVFoundation could not read media metadata: \(error.localizedDescription)")
        }
    }

    private static func inspect(_ track: AVAssetTrack) async throws -> TrackAudit {
        let time = try await track.load(.timeRange)
        let natural = track.mediaType == .video ? try await track.load(.naturalSize) : .zero
        let nominalFPS = track.mediaType == .video ? try await track.load(.nominalFrameRate) : 0
        let descriptions = try await track.load(.formatDescriptions)
        var encodedWidth: Int?
        var encodedHeight: Int?
        var sampleRate: Double?
        var channelCount: Int?
        var codec: String?
        if let description = descriptions.first {
            codec = fourCCString(CMFormatDescriptionGetMediaSubType(description))
            if track.mediaType == .video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                encodedWidth = Int(dimensions.width)
                encodedHeight = Int(dimensions.height)
            } else if track.mediaType == .audio,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                sampleRate = asbd.mSampleRate.isFinite && asbd.mSampleRate > 0 ? asbd.mSampleRate : nil
                channelCount = Int(asbd.mChannelsPerFrame)
            }
        }
        let range = time.start.isValid && time.start.seconds.isFinite &&
                    time.duration.isValid && time.duration.seconds.isFinite && time.duration.seconds > 0
            ? MediaRange(startSeconds: time.start.seconds, durationSeconds: time.duration.seconds) : nil
        var audit = TrackAudit(mediaType: track.mediaType.rawValue, timeRange: range,
            naturalWidth: track.mediaType == .video ? Double(natural.width) : nil,
            naturalHeight: track.mediaType == .video ? Double(natural.height) : nil,
            encodedWidth: encodedWidth, encodedHeight: encodedHeight,
            nominalFrameRate: nominalFPS > 0 ? nominalFPS : nil,
            sampleRate: sampleRate, channelCount: channelCount, codec: codec, rangeToleranceSeconds: nil)
        audit.rangeToleranceSeconds = codecBoundaryTolerance(for: audit)
        return audit
    }

    private static func compareDeclaredMetadata(_ segment: InputSegment, tracks: [TrackAudit], issues: inout [String]) {
        if let width = segment.width, let actual = tracks.first(where: { $0.mediaType == AVMediaType.video.rawValue })?.encodedWidth,
           width != actual { issues.append("declared width \(width) differs from encoded video width \(actual)") }
        if let height = segment.height, let actual = tracks.first(where: { $0.mediaType == AVMediaType.video.rawValue })?.encodedHeight,
           height != actual { issues.append("declared height \(height) differs from encoded video height \(actual)") }
        if let rate = segment.sampleRate, let actual = tracks.first(where: { $0.mediaType == AVMediaType.audio.rawValue })?.sampleRate,
           abs(Double(rate) - actual) > 1 { issues.append("declared sample rate \(rate) differs from encoded sample rate \(actual)") }
        if let channels = segment.channelCount, let actual = tracks.first(where: { $0.mediaType == AVMediaType.audio.rawValue })?.channelCount,
           channels != actual { issues.append("declared channel count \(channels) differs from encoded channel count \(actual)") }
    }

    private static func codecBoundaryTolerance(for track: TrackAudit) -> Double {
        if track.mediaType == AVMediaType.video.rawValue {
            // One encoded video frame accounts for H.264 frame-boundary rounding.
            return 1.0 / Double(track.nominalFrameRate ?? 30)
        }
        let codec = track.codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if codec == "aac" || codec == "mp4a" {
            // AAC-LC access units contain 1024 samples; allow two units for priming/padding.
            return 2.0 * 1024.0 / (track.sampleRate ?? 48_000)
        }
        // Other audio codecs receive at most one sample of timestamp rounding, not AAC padding.
        return 1.0 / (track.sampleRate ?? 1_000)
    }

    private static func expectedMediaType(sourceID: String, kind: String?) -> String? {
        switch kind {
        case "screen", "camera": AVMediaType.video.rawValue
        case "microphone", "systemAudio": AVMediaType.audio.rawValue
        default:
            if sourceID == "screen" || sourceID.hasPrefix("camera") { AVMediaType.video.rawValue }
            else if sourceID == "microphone" || sourceID == "systemAudio" { AVMediaType.audio.rawValue }
            else { nil }
        }
    }

    private static func timelineAudits(_ segments: [InputSegment]) -> [SourceTimelineAudit] {
        let groups = Dictionary(grouping: segments, by: \.sourceID)
        return groups.keys.sorted().map { sourceID in
            let group = groups[sourceID] ?? []
            let invalid = group.filter {
                $0.timelineStartMicroseconds < 0 || $0.durationMicroseconds <= 0 ||
                safeEnd($0.timelineStartMicroseconds, $0.durationMicroseconds) == nil
            }
            let ordered = group.filter {
                $0.timelineStartMicroseconds >= 0 && $0.durationMicroseconds > 0 &&
                safeEnd($0.timelineStartMicroseconds, $0.durationMicroseconds) != nil
            }
                .sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
            var issues: [TimelineIssue] = []
            var gaps = 0
            var overlaps = 0
            var invalidRanges = invalid.count
            for segment in invalid {
                issues.append(TimelineIssue(previousSegmentID: segment.id, nextSegmentID: nil,
                    kind: "invalidRange", deltaMicroseconds: 0))
            }
            for pair in zip(ordered, ordered.dropFirst()) {
                guard let previousEnd = safeEnd(pair.0.timelineStartMicroseconds, pair.0.durationMicroseconds) else {
                    invalidRanges += 1
                    issues.append(TimelineIssue(previousSegmentID: pair.0.id, nextSegmentID: pair.1.id,
                        kind: "invalidRange", deltaMicroseconds: 0))
                    continue
                }
                let (delta, overflow) = pair.1.timelineStartMicroseconds.subtractingReportingOverflow(previousEnd)
                if overflow {
                    invalidRanges += 1
                    issues.append(TimelineIssue(previousSegmentID: pair.0.id, nextSegmentID: pair.1.id,
                        kind: "invalidRange", deltaMicroseconds: 0))
                } else if delta > 1_000 {
                    gaps += 1
                    issues.append(TimelineIssue(previousSegmentID: pair.0.id, nextSegmentID: pair.1.id,
                        kind: "gap", deltaMicroseconds: delta))
                } else if delta < -1_000 {
                    overlaps += 1
                    issues.append(TimelineIssue(previousSegmentID: pair.0.id, nextSegmentID: pair.1.id,
                        kind: "overlap", deltaMicroseconds: delta))
                }
            }
            let first = ordered.first?.timelineStartMicroseconds
            let last = ordered.compactMap { safeEnd($0.timelineStartMicroseconds, $0.durationMicroseconds) }.max()
            return SourceTimelineAudit(sourceID: sourceID, segmentCount: ordered.count,
                firstStartMicroseconds: first, lastEndMicroseconds: last, timelineIssues: issues,
                gapCount: gaps, overlapCount: overlaps, invalidRangeCount: invalidRanges)
        }
    }

    private static func safeMediaURL(_ path: String, root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func failed(_ segment: InputSegment, mediaStart: Int64, mediaEnd: Int64,
                               issue: String, isPlayable: Bool? = nil) -> SegmentAudit {
        let timelineEnd = safeEnd(segment.timelineStartMicroseconds, segment.durationMicroseconds) ?? segment.timelineStartMicroseconds
        return SegmentAudit(id: segment.id, sourceID: segment.sourceID, relativePath: segment.relativePath,
            timelineRangeMicroseconds: [segment.timelineStartMicroseconds, timelineEnd],
            declaredMediaRangeMicroseconds: [mediaStart, mediaEnd], assetDurationSeconds: nil, isPlayable: isPlayable,
            tracks: [], status: "failed", issues: [issue])
    }

    private static func safeEnd(_ start: Int64, _ duration: Int64) -> Int64? {
        let (end, overflow) = start.addingReportingOverflow(duration)
        return overflow ? nil : end
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", code)
    }
}
