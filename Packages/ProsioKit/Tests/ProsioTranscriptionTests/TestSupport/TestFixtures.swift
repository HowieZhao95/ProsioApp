import Foundation
import ProsioCore

/// Thread-safe accumulator for events collected from a background consumer `Task` in tests.
actor CollectedEvents {
    private(set) var values: [TranscriptEvent] = []
    func append(_ event: TranscriptEvent) { values.append(event) }
}

enum TestFixtures {
    static func audioChunk(pcm16 samples: [Int16] = [1, 2, 3, 4], level: Float = 0.5, timestamp: TimeInterval = 0) -> AudioChunk {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let unsigned = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: unsigned))
            data.append(UInt8(truncatingIfNeeded: unsigned >> 8))
        }
        return AudioChunk(pcm16: data, level: level, timestamp: timestamp)
    }
}
