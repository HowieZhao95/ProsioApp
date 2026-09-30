import AVFoundation
import Foundation

nonisolated enum RecordingEditor: String, CaseIterable, Identifiable, Sendable {
    case finalCutPro, resolve, premiere, jianying
    var id: String { rawValue }
    var title: String {
        switch self {
        case .finalCutPro: "Final Cut Pro"
        case .resolve: "DaVinci Resolve"
        case .premiere: "Premiere Pro"
        case .jianying: "剪映（实验性草稿）"
        }
    }
    var fileExtension: String { self == .finalCutPro ? "fcpxml" : self == .jianying ? "json" : "xml" }
    var importVerificationNote: String {
        switch self {
        case .finalCutPro: "生成原生多机位 FCPXML；当前软件版本的导入与同步仍需实机验收。"
        case .resolve, .premiere: "生成已对齐的独立视频和音频轨道。导入后可创建多机位；原生多机位转换需在软件中完成。"
        case .jianying: "实验性未加密草稿，保留微秒对齐。剪映版本可能不兼容；不会自动改写现有草稿，请先备份并验证。"
        }
    }
}

nonisolated enum RecordingExportError: LocalizedError {
    case invalidManifest(String), unsafePath(String), missingMedia(String), destinationExists, noVideo, invalidTrim, exportFailed(String)
    var errorDescription: String? {
        switch self {
        case let .invalidManifest(reason): "录制清单无效：\(reason)"
        case let .unsafePath(path): "素材路径不安全：\(path)"
        case let .missingMedia(path): "素材缺失或不可读取：\(path)"
        case .destinationExists: "导出目标已存在，请选择其他名称。"
        case .noVideo: "所选来源没有可预览的视频。"
        case .invalidTrim: "裁剪时间不在录制范围内。"
        case let .exportFailed(reason): "导出失败：\(reason)"
        }
    }
}

@MainActor
enum RecordingExportSupport {
    static let timescale: CMTimeScale = 1_000_000
    static func time(_ microseconds: Int64) -> CMTime { CMTime(value: microseconds, timescale: timescale) }

    static func mediaURL(_ relativePath: String, in directory: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw RecordingExportError.unsafePath(relativePath)
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw RecordingExportError.unsafePath(relativePath) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true else { throw RecordingExportError.missingMedia(relativePath) }
        return url
    }

    static func validate(_ session: RecordingSessionManifest) throws {
        guard session.schemaVersion == 1, !session.segments.isEmpty,
              Set(session.sources.map(\.id)).count == session.sources.count,
              Set(session.segments.map(\.id)).count == session.segments.count else {
            throw RecordingExportError.invalidManifest("版本、来源或片段标识不完整")
        }
        let ids = Set(session.sources.map(\.id))
        for source in session.sources {
            var end: Int64 = 0
            for segment in session.segments.filter({ $0.sourceID == source.id }).sorted(by: { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }) {
                guard segment.durationMicroseconds > 0, segment.timelineStartMicroseconds >= end,
                      segment.mediaStartMicroseconds >= 0, let nextEnd = segment.timelineEndMicroseconds,
                      !segment.mediaStartMicroseconds.addingReportingOverflow(segment.durationMicroseconds).overflow else {
                    throw RecordingExportError.invalidManifest("片段时间无效或重叠")
                }
                end = nextEnd
            }
        }
        guard session.segments.allSatisfy({ ids.contains($0.sourceID) }) else {
            throw RecordingExportError.invalidManifest("片段来源不存在")
        }
    }

    nonisolated static func copyMedia(from source: URL, to destination: URL) async throws {
        let job = Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw RecordingExportError.exportFailed("无法创建素材副本")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    static func inspectedMedia(_ segment: RecordingSegment, source: RecordingSource, directory: URL) async throws -> RecordingMediaInfo {
        let url = try mediaURL(segment.relativePath, in: directory)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let isVideo = source.kind == .screen || source.kind == .camera
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
              duration.seconds + 0.002 >= Double(segment.mediaStartMicroseconds + segment.durationMicroseconds) / 1_000_000,
              let track = try await asset.loadTracks(withMediaType: isVideo ? .video : .audio).first else {
            throw RecordingExportError.missingMedia(segment.relativePath)
        }
        if isVideo {
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let minFrameDuration = try await track.load(.minFrameDuration)
            let standardRates: [CMTime] = [CMTime(value: 1001, timescale: 24000), CMTime(value: 1, timescale: 24), CMTime(value: 1, timescale: 25), CMTime(value: 1001, timescale: 30000), CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 50), CMTime(value: 1001, timescale: 60000), CMTime(value: 1, timescale: 60)]
            let nearest = standardRates.min { abs(1 / $0.seconds - Double(fps)) < abs(1 / $1.seconds - Double(fps)) }
            let frameDuration: CMTime
            if let nearest, abs(1 / nearest.seconds - Double(fps)) < 0.015 { frameDuration = nearest }
            else if minFrameDuration.isNumeric && minFrameDuration.value > 0 { frameDuration = minFrameDuration }
            else { frameDuration = CMTime(value: 1, timescale: max(1, Int32(fps.rounded()))) }
            return RecordingMediaInfo(segment: segment, source: source, url: url, duration: duration, width: Int(size.width), height: Int(size.height), frameDuration: frameDuration, sampleRate: nil, channels: nil)
        }
        let descriptions = try await track.load(.formatDescriptions)
        let audio = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return RecordingMediaInfo(segment: segment, source: source, url: url, duration: duration, width: nil, height: nil, frameDuration: nil, sampleRate: audio.map { Int($0.mSampleRate) }, channels: audio.map { Int($0.mChannelsPerFrame) })
    }
}

struct RecordingMediaInfo {
    let segment: RecordingSegment
    let source: RecordingSource
    let url: URL
    let duration: CMTime
    let width: Int?
    let height: Int?
    let frameDuration: CMTime?
    let sampleRate: Int?
    let channels: Int?
    var isVideo: Bool { source.kind == .screen || source.kind == .camera }
}
