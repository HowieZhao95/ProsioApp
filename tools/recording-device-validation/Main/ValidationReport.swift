import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

nonisolated struct ValidationPermissionSnapshot: Codable, Sendable {
    let screen: Bool
    let camera: String
    let microphone: String

    @MainActor static func read() -> Self {
        Self(screen: CGPreflightScreenCaptureAccess(), camera: label(AVCaptureDevice.authorizationStatus(for: .video)),
             microphone: label(AVCaptureDevice.authorizationStatus(for: .audio)))
    }
    private static func label(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "已授权"
        case .notDetermined: "未请求"
        case .denied: "未授权"
        case .restricted: "受系统限制"
        @unknown default: "未知"
        }
    }
}

nonisolated struct ValidationBuildEvidence: Codable, Sendable {
    let revision: String
    let workingTreeDirty: Bool
    let builtAtUTC: String
    let sourceSHA256: [String: String]

    static func load(from url: URL?) throws -> Self {
        do {
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let evidence = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
            guard !evidence.revision.isEmpty, !evidence.builtAtUTC.isEmpty,
                  evidence.sourceSHA256.count == 15,
                  evidence.sourceSHA256.values.allSatisfy({ hash in
                      hash.count == 64 && hash.unicodeScalars.allSatisfy { hexadecimal.contains($0) }
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            return evidence
        } catch {
            throw NSError(domain: "RecordingDeviceValidation", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "验收工具的源码身份文件缺失或无效，未请求权限或开始捕获；请重新构建工具。",
                           NSUnderlyingErrorKey: error])
        }
    }
}

nonisolated struct ValidationEvent: Codable, Sendable {
    let date: Date
    let hostTimeMicroseconds: Int64
    let kind: String
    let message: String
    let sourceID: String?
    let available: Bool?
}

nonisolated struct ValidationMediaEvidence: Codable, Sendable {
    let segment: RecordingSegment
    let playable: Bool
    let bytes: Int64?
    let actualDurationMicroseconds: Int64?
    let actualWidth: Int?
    let actualHeight: Int?
    let actualSampleRate: Double?
    let actualChannels: Int?
    let error: String?
    let audioSignal: ValidationAudioSignal?
}

nonisolated struct ValidationAudioSignal: Codable, Sendable {
    let decodedSamples: Int
    let peakAmplitude: Double
    let rmsAmplitude: Double
    let inspectedSeconds: Double
    let interpretation = "仅说明所采样音轨是否含非零声音；不证明 fixture 提示音被捕获，也不证明音画同步。"
}

nonisolated struct ValidationSourceGap: Codable, Sendable {
    let sourceID: String
    let startMicroseconds: Int64
    let endMicroseconds: Int64
}

nonisolated struct ValidationReport: Codable, Sendable {
    let schemaVersion = 1
    let attemptID: UUID
    let startedAt: Date
    var endedAt: Date?
    var elapsedActiveSeconds: Double?
    let operatingSystem: String
    let validationBundleID: String
    let fixtureBundleID: String
    var build: ValidationBuildEvidence?
    let requestedDurationSeconds: Int
    let selectedCameras: [RecordingSource]
    let selectedMicrophone: RecordingSource?
    let requestedSystemAudio: Bool
    var permissions: ValidationPermissionSnapshot
    var fixture: ValidationFixtureHandshake?
    var configuration: RecordingConfiguration?
    var session: RecordingSessionManifest?
    var sessionDirectory: String?
    var events: [ValidationEvent] = []
    var fixtureSignalEvents: [ValidationSignalEvent] = []
    var media: [ValidationMediaEvidence] = []
    var gaps: [ValidationSourceGap] = []
    var sourceEvidence: [ValidationSourceEvidence] = []
    var failures: [String] = []
    var completion: String = "preparing"
    let evidenceLimit = "此报告验证真实生产引擎、媒体写盘、可播放性与时间偏移。录制时长或时间戳一致不证明两小时口型漂移，仍需实拍打板/可见时钟与音频标记及剪辑软件验收。"
}

nonisolated enum ValidationReportFinalizer {
    static func finish(_ report: ValidationReport, elapsedActiveSeconds: Double, endedAt: Date,
                       permissions: ValidationPermissionSnapshot) -> ValidationReport {
        // Compute from a read-only snapshot before mutating the returned value.
        let completion = report.failures.isEmpty
            ? (report.media.isEmpty ? "cancelledBeforeCapture" : "mediaMetadataVerified") : "failed"
        var result = report
        result.elapsedActiveSeconds = elapsedActiveSeconds
        result.endedAt = endedAt
        result.permissions = permissions
        result.completion = completion
        return result
    }
}

nonisolated struct ValidationSourceEvidence: Codable, Sendable {
    let source: RecordingSource
    let completedSegments: Int
    let playableSegments: Int
    let firstTimelineStartMicroseconds: Int64?
    let lastTimelineEndMicroseconds: Int64?
    let status: String
}

@MainActor enum ValidationReportInspector {
    static func inspect(_ session: RecordingSessionManifest, in directory: URL) async -> [ValidationMediaEvidence] {
        var result: [ValidationMediaEvidence] = []
        for segment in session.segments {
            let url = directory.appendingPathComponent(segment.relativePath)
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                let video = try await asset.loadTracks(withMediaType: .video).first
                let audio = try await asset.loadTracks(withMediaType: .audio).first
                let size = try await video?.load(.naturalSize)
                let descriptions = try await audio?.load(.formatDescriptions)
                let format = descriptions?.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                guard playable, duration.isNumeric, duration > .zero, video != nil || audio != nil else {
                    throw NSError(domain: "RecordingDeviceValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "片段没有可播放的媒体轨道。"])
                }
                result.append(ValidationMediaEvidence(segment: segment, playable: true, bytes: bytes,
                    actualDurationMicroseconds: CMTimeConvertScale(duration, timescale: 1_000_000, method: .roundHalfAwayFromZero).value,
                    actualWidth: size.map { Int($0.width) }, actualHeight: size.map { Int($0.height) },
                    actualSampleRate: format?.mSampleRate, actualChannels: format.map { Int($0.mChannelsPerFrame) }, error: nil,
                    audioSignal: audio.flatMap { try? readAudioSignal(asset: asset, track: $0, duration: duration) }))
            } catch {
                result.append(ValidationMediaEvidence(segment: segment, playable: false, bytes: nil,
                    actualDurationMicroseconds: nil, actualWidth: nil, actualHeight: nil,
                    actualSampleRate: nil, actualChannels: nil, error: error.localizedDescription, audioSignal: nil))
            }
        }
        return result
    }

    private static func readAudioSignal(asset: AVAsset, track: AVAssetTrack, duration: CMTime) throws -> ValidationAudioSignal {
        let reader = try AVAssetReader(asset: asset)
        let seconds = min(10, duration.seconds)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw RecordingPlatformError.encoding("无法检查音轨采样。") }
        reader.add(output)
        guard reader.startReading() else { throw RecordingPlatformError.encoding("无法解码音轨采样。") }
        var count = 0
        var peak = 0.0
        var squared = 0.0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes > 0, bytes.isMultiple(of: MemoryLayout<Float>.size) else { continue }
            var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let copied = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard copied == noErr else { throw RecordingPlatformError.encoding("音轨采样读取失败。") }
            for value in values {
                let amplitude = Double(value)
                guard amplitude.isFinite else { throw RecordingPlatformError.encoding("音轨采样包含非有限数值。") }
                peak = max(peak, abs(amplitude))
                squared += amplitude * amplitude
                count += 1
            }
        }
        guard reader.status == .completed, count > 0 else { throw RecordingPlatformError.encoding("音轨未完成采样解码。") }
        return ValidationAudioSignal(decodedSamples: count, peakAmplitude: peak, rmsAmplitude: sqrt(squared / Double(count)), inspectedSeconds: seconds)
    }

    static func gaps(_ session: RecordingSessionManifest) -> [ValidationSourceGap] {
        var result: [ValidationSourceGap] = []
        for source in session.sources {
            var end: Int64 = 0
            for segment in session.segments.filter({ $0.sourceID == source.id }).sorted(by: { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }) {
                if segment.timelineStartMicroseconds > end {
                    result.append(ValidationSourceGap(sourceID: source.id, startMicroseconds: end, endMicroseconds: segment.timelineStartMicroseconds))
                }
                end = max(end, segment.timelineEndMicroseconds ?? end)
            }
            if end < session.durationMicroseconds {
                result.append(ValidationSourceGap(sourceID: source.id, startMicroseconds: end, endMicroseconds: session.durationMicroseconds))
            }
        }
        return result
    }

    static func sources(_ session: RecordingSessionManifest, media: [ValidationMediaEvidence]) -> [ValidationSourceEvidence] {
        session.sources.map { source in
            let segments = session.segments.filter { $0.sourceID == source.id }
            let playable = media.filter { $0.segment.sourceID == source.id && $0.playable }.count
            return ValidationSourceEvidence(source: source, completedSegments: segments.count, playableSegments: playable,
                firstTimelineStartMicroseconds: segments.map(\.timelineStartMicroseconds).min(),
                lastTimelineEndMicroseconds: segments.compactMap(\.timelineEndMicroseconds).max(),
                status: segments.isEmpty ? "missing" : playable == segments.count ? "mediaMetadataVerified" : "notVerified")
        }
    }

    static func hostMicroseconds() -> Int64 {
        CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }
}
