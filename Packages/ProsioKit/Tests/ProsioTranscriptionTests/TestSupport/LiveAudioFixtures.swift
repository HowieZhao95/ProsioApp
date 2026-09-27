import Foundation
import ProsioCore

enum LiveAudioFixtures {
    /// Returns the payload of the WAV `data` chunk.
    static func pcmData(fromWAV wav: Data) throws -> Data {
        guard let range = wav.range(of: Data("data".utf8)) else { throw ProsioError.audioUnavailable("no data chunk") }
        return wav.subdata(in: (range.upperBound + 4)..<wav.endIndex)
    }
}
