import Foundation

nonisolated enum RecordingSourceKind: String, Codable, Sendable {
    case screen
    case camera
    case microphone
    case systemAudio
}

nonisolated struct RecordingSource: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: RecordingSourceKind
    var name: String
    var deviceID: String?

    init(id: String, kind: RecordingSourceKind, name: String, deviceID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.deviceID = deviceID
    }
}

nonisolated struct RecordingRegion: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

nonisolated enum RecordingScreenTarget: Codable, Hashable, Sendable {
    case display(UInt32)
    case window(UInt32)
    case region(displayID: UInt32, rect: RecordingRegion)
}

nonisolated enum RecordingConfigurationError: Error, Equatable, Sendable {
    case tooManyCameras
    case duplicateSourceID(String)
    case invalidSourceKind(String)
    case invalidRegion
    case invalidFrameRate
    case invalidSegmentDuration
}

nonisolated struct RecordingConfiguration: Codable, Hashable, Sendable {
    var screenTarget: RecordingScreenTarget
    var cameras: [RecordingSource]
    var microphone: RecordingSource?
    var capturesSystemAudio: Bool
    var showsCursor: Bool
    var framesPerSecond: Int
    var segmentDurationSeconds: Double

    init(
        screenTarget: RecordingScreenTarget,
        cameras: [RecordingSource] = [],
        microphone: RecordingSource? = nil,
        capturesSystemAudio: Bool = true,
        showsCursor: Bool = true,
        framesPerSecond: Int = 30,
        segmentDurationSeconds: Double = 60
    ) {
        self.screenTarget = screenTarget
        self.cameras = cameras
        self.microphone = microphone
        self.capturesSystemAudio = capturesSystemAudio
        self.showsCursor = showsCursor
        self.framesPerSecond = framesPerSecond
        self.segmentDurationSeconds = segmentDurationSeconds
    }

    func validate() throws {
        guard cameras.count <= 2 else { throw RecordingConfigurationError.tooManyCameras }
        if case let .region(_, rect) = screenTarget, !rect.isValid {
            throw RecordingConfigurationError.invalidRegion
        }
        guard (15...60).contains(framesPerSecond) else { throw RecordingConfigurationError.invalidFrameRate }
        guard segmentDurationSeconds.isFinite, (5...300).contains(segmentDurationSeconds) else {
            throw RecordingConfigurationError.invalidSegmentDuration
        }

        var seen: Set<String> = ["screen"]
        if capturesSystemAudio { seen.insert("systemAudio") }
        for source in cameras {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingConfigurationError.invalidSourceKind(source.id)
            }
            guard source.kind == .camera else { throw RecordingConfigurationError.invalidSourceKind(source.id) }
            guard seen.insert(source.id).inserted else { throw RecordingConfigurationError.duplicateSourceID(source.id) }
        }
        if let microphone {
            guard !microphone.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingConfigurationError.invalidSourceKind(microphone.id)
            }
            guard microphone.kind == .microphone else { throw RecordingConfigurationError.invalidSourceKind(microphone.id) }
            guard seen.insert(microphone.id).inserted else { throw RecordingConfigurationError.duplicateSourceID(microphone.id) }
        }
    }
}

nonisolated struct RecordingSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceID: String
    var relativePath: String
    var timelineStartMicroseconds: Int64
    var mediaStartMicroseconds: Int64
    var durationMicroseconds: Int64
    var width: Int?
    var height: Int?
    var sampleRate: Int?
    var channelCount: Int?

    init(
        id: UUID = UUID(),
        sourceID: String,
        relativePath: String,
        timelineStartMicroseconds: Int64,
        mediaStartMicroseconds: Int64 = 0,
        durationMicroseconds: Int64,
        width: Int? = nil,
        height: Int? = nil,
        sampleRate: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.timelineStartMicroseconds = timelineStartMicroseconds
        self.mediaStartMicroseconds = mediaStartMicroseconds
        self.durationMicroseconds = durationMicroseconds
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    var timelineEndMicroseconds: Int64? {
        let (end, overflow) = timelineStartMicroseconds.addingReportingOverflow(durationMicroseconds)
        return overflow ? nil : end
    }
}

nonisolated enum RecordingPhase: String, Codable, Sendable {
    case preparing
    case recording
    case paused
    case finalizing
    case ready
    case interrupted
    case failed
}

nonisolated struct RecordingSessionManifest: Identifiable, Codable, Hashable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var phase: RecordingPhase
    var sources: [RecordingSource]
    var segments: [RecordingSegment]
    var warnings: [String]

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        title: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        phase: RecordingPhase = .preparing,
        sources: [RecordingSource],
        segments: [RecordingSegment] = [],
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.phase = phase
        self.sources = sources
        self.segments = segments
        self.warnings = warnings
    }

    var durationMicroseconds: Int64 {
        segments.compactMap(\.timelineEndMicroseconds).max() ?? 0
    }
}
