import CoreMedia
import Foundation

/// A single host-clock timeline. Pauses remove time; disconnected sources leave gaps.
nonisolated struct RecordingTimeline: Sendable {
    private(set) var origin: CMTime
    private(set) var excluded = CMTime.zero
    private(set) var pausedAt: CMTime?
    private(set) var acceptsAfter: CMTime

    init(origin: CMTime) {
        self.origin = origin
        acceptsAfter = origin
    }

    mutating func pause(at time: CMTime) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }

    mutating func resume(at time: CMTime) {
        guard let pausedAt else { return }
        excluded = excluded + max(.zero, time - pausedAt)
        self.pausedAt = nil
        acceptsAfter = time
    }

    func offset(for timestamp: CMTime) -> Int64? {
        guard pausedAt == nil, timestamp.isNumeric, timestamp >= acceptsAfter else { return nil }
        let offset = timestamp - origin - excluded
        guard offset >= .zero else { return nil }
        return CMTimeConvertScale(offset, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }
}

nonisolated enum RecordingPlatformError: LocalizedError {
    case unavailable(String)
    case invalidState
    case storage(String)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .storage(let message), .encoding(let message): message
        case .invalidState: "录制状态已改变，请重新开始。"
        }
    }
}
