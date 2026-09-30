import AVFoundation
import Foundation

/// Reconciles durable per-chunk receipts with the session manifest after an interrupted
/// process. Neither invalid receipts nor unreadable media are deleted.
@MainActor
enum RecordingRecovery {
    static func recover(_ session: RecordingSessionManifest, in directory: URL) async -> RecordingSessionManifest {
        var recovered = session
        let decoder = JSONDecoder()
        let media = directory.appendingPathComponent("media", isDirectory: true)
        let receipts = (try? FileManager.default.contentsOfDirectory(at: media,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        for receipt in receipts where receipt.lastPathComponent.hasSuffix(".segment.json") {
            do {
                let receiptURL = try RecordingExportSupport.mediaURL("media/" + receipt.lastPathComponent, in: directory)
                let segment = try decoder.decode(RecordingSegment.self, from: Data(contentsOf: receiptURL))
                guard !recovered.segments.contains(where: { $0.id == segment.id }) else { continue }
                guard receipt.lastPathComponent == "\(segment.id.uuidString).segment.json",
                      segment.relativePath == "media/\(segment.id.uuidString).mov"
                        || segment.relativePath == "media/\(segment.id.uuidString).m4a",
                      let source = recovered.sources.first(where: { $0.id == segment.sourceID }) else {
                    throw RecordingExportError.invalidManifest("片段恢复记录不匹配")
                }
                var proposed = recovered
                proposed.segments.append(segment)
                try RecordingExportSupport.validate(proposed)
                var candidate = segment
                let final = directory.appendingPathComponent(segment.relativePath)
                var shouldRename = false
                if !FileManager.default.fileExists(atPath: final.path) {
                    candidate.relativePath = "media/\(segment.id.uuidString).partial.\(final.pathExtension)"
                    shouldRename = true
                }
                _ = try await RecordingExportSupport.inspectedMedia(candidate, source: source, directory: directory)
                let url = try RecordingExportSupport.mediaURL(candidate.relativePath, in: directory)
                guard try await AVURLAsset(url: url).load(.isPlayable) else {
                    throw RecordingExportError.missingMedia(candidate.relativePath)
                }
                if shouldRename { try FileManager.default.moveItem(at: url, to: final) }
                recovered = proposed
                recovered.phase = .interrupted
                addWarning("已恢复一个完成写盘的片段；其他未完成文件仍保留在原片文件夹。", to: &recovered)
            } catch {
                addWarning("有片段恢复记录无法使用，原始文件保留：\(receipt.lastPathComponent)", to: &recovered)
            }
        }
        var playable: [RecordingSegment] = []
        for segment in recovered.segments {
            do {
                guard let source = recovered.sources.first(where: { $0.id == segment.sourceID }) else {
                    throw RecordingExportError.invalidManifest("来源不存在")
                }
                _ = try await RecordingExportSupport.inspectedMedia(segment, source: source, directory: directory)
                let url = try RecordingExportSupport.mediaURL(segment.relativePath, in: directory)
                guard try await AVURLAsset(url: url).load(.isPlayable) else {
                    throw RecordingExportError.missingMedia(segment.relativePath)
                }
                playable.append(segment)
            } catch {
                addWarning("片段无法播放，已保留原文件：\(segment.relativePath)", to: &recovered)
                recovered.phase = .interrupted
            }
        }
        recovered.segments = playable
        return recovered
    }

    private static func addWarning(_ warning: String, to session: inout RecordingSessionManifest) {
        if !session.warnings.contains(warning) { session.warnings.append(warning) }
    }
}
