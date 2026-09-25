import Foundation
import Testing
@testable import ProsioTranscription

@Suite struct GatewayAudioSupportTests {

    @Test func int16LittleEndianRoundTrip() {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min, 12345, -12345]
        let data = int16SamplesToLittleEndianData(samples)
        #expect(data.count == samples.count * 2)
        #expect(int16SamplesFromLittleEndianData(data) == samples)
    }

    @Test func int16LittleEndianData_isExplicitlyLittleEndian() {
        // 0x0102 packed little-endian must be byte 0x02 then 0x01, regardless of host endianness.
        let data = int16SamplesToLittleEndianData([0x0102])
        #expect(Array(data) == [0x02, 0x01])
    }

    @Test func dataChunked_splitsAtMaxBytes() {
        let data = Data(repeating: 0xAB, count: 150_000)
        let chunks = data.chunked(maxBytes: 64 * 1024)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 65_536)
        #expect(chunks[1].count == 65_536)
        #expect(chunks[2].count == 150_000 - 2 * 65_536)
        #expect(chunks.reduce(Data()) { $0 + $1 } == data)
    }

    @Test func dataChunked_smallerThanMax_singleChunk() {
        let data = Data(repeating: 1, count: 100)
        let chunks = data.chunked(maxBytes: 64 * 1024)
        #expect(chunks == [data])
    }

    @Test func dataChunked_empty_noChunks() {
        #expect(Data().chunked(maxBytes: 1024).isEmpty)
    }
}
