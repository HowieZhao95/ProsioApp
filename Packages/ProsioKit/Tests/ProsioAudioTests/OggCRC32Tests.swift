import Foundation
import Testing
@testable import ProsioAudio

/// Known-vector tests for `OggCRC32`. Reference values were computed independently with a
/// from-scratch Python implementation of the same documented algorithm (non-reflected, poly
/// 0x04C11DB7, init 0, no final XOR — i.e. libogg's `framing.c` `crc_lookup` table + update rule),
/// not derived from `OggCRC32` itself, so they exercise the implementation rather than restate it.
@Suite struct OggCRC32Tests {
    @Test func emptyData_isZero() {
        #expect(OggCRC32.checksum(Data()) == 0x0000_0000)
    }

    @Test func singleZeroByte_isZero() {
        #expect(OggCRC32.checksum(Data([0x00])) == 0x0000_0000)
    }

    @Test func knownVector_oggS() {
        #expect(OggCRC32.checksum(Data("OggS".utf8)) == 0x5fb0_a94f)
    }

    @Test func knownVector_byteSequence0Through9() {
        let data = Data((0..<10).map { UInt8($0) })
        #expect(OggCRC32.checksum(data) == 0xfc86_ea3b)
    }

    @Test func knownVector_pangram() {
        let data = Data("The quick brown fox jumps over the lazy dog".utf8)
        #expect(OggCRC32.checksum(data) == 0xc948_7f7e)
    }

    @Test func differentInputs_differentChecksums() {
        let a = OggCRC32.checksum(Data("hello".utf8))
        let b = OggCRC32.checksum(Data("hellp".utf8))
        #expect(a != b)
    }
}
