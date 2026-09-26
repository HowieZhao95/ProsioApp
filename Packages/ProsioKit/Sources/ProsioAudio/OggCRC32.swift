import Foundation

/// CRC-32 as used by the Ogg container format (RFC 3533 / RFC 7845): polynomial 0x04C11DB7,
/// non-reflected, initial value 0, no final XOR — NOT the same algorithm as `zlib`/`Foundation`'s
/// CRC-32 (which is bit-reflected). This matches the reference implementation in libogg's
/// `framing.c` (`crc_lookup` generation + `crc_reg = (crc_reg << 8) ^ table[((crc_reg >> 24) ^ byte) & 0xff]`).
enum OggCRC32 {
    static let polynomial: UInt32 = 0x04c1_1db7

    static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var r = UInt32(i) << 24
            for _ in 0..<8 {
                if (r & 0x8000_0000) != 0 {
                    r = (r << 1) ^ polynomial
                } else {
                    r = r << 1
                }
            }
            table[i] = r
        }
        return table
    }()

    /// Checksum of `data`, computed with any embedded CRC field already zeroed by the caller.
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            let index = Int(((crc >> 24) ^ UInt32(byte)) & 0xff)
            crc = (crc << 8) ^ table[index]
        }
        return crc
    }
}
