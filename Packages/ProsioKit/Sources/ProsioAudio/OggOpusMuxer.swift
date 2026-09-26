import Foundation

/// Minimal RFC 7845 Ogg/Opus muxer: wraps raw Opus packets (as produced by `OggOpusEncoder`) in an
/// Ogg bitstream — `OpusHead`, `OpusTags`, then one or more audio pages with correct granule
/// positions (48 kHz units, per spec, regardless of the actual encode sample rate), segment
/// tables, CRC-32 (`OggCRC32`), and the end-of-stream flag on the last page.
struct OggOpusMuxer {
    /// Ogg granule positions for Opus are always expressed in 48 kHz-equivalent samples.
    static let granuleRate: Int64 = 48_000

    let channelCount: UInt8
    /// Pre-skip in 48 kHz-equivalent samples (RFC 7845 §5.1) — the number of samples to discard
    /// from the start of decoder output (covers the encoder's algorithmic look-ahead/priming).
    let preSkip: UInt16
    /// Informational "input sample rate" field in `OpusHead` (the rate before any resampling done
    /// before encoding). Does not affect decoding.
    let inputSampleRate: UInt32

    private let serial: UInt32 = UInt32.random(in: UInt32.min...UInt32.max)

    /// Muxes `packets` (each one already-encoded 20 ms Opus frame) into a complete Ogg file.
    /// - Parameter frameDuration48k: granule-position increment per packet, in 48 kHz samples
    ///   (960 for a 20 ms frame).
    func mux(packets: [Data], frameDuration48k: Int64 = 960) -> Data {
        var out = Data()
        var pageSequence: UInt32 = 0

        out += makePage(sequence: pageSequence, granulePosition: 0, packets: [makeOpusHeadPacket()], headerType: 0x02)
        pageSequence += 1

        out += makePage(sequence: pageSequence, granulePosition: 0, packets: [makeOpusTagsPacket()], headerType: 0x00)
        pageSequence += 1

        guard !packets.isEmpty else {
            // No audio packets: still a structurally valid (silent) Ogg/Opus stream — mark the
            // last header page itself as EOS by re-emitting it is wasteful; instead emit an empty
            // EOS page.
            out += makePage(sequence: pageSequence, granulePosition: 0, packets: [], headerType: 0x04)
            return out
        }

        var granule: Int64 = 0
        var batch: [Data] = []
        var segmentsInBatch = 0

        func segmentsNeeded(forPacketByteCount count: Int) -> Int { count / 255 + 1 }

        for (index, packet) in packets.enumerated() {
            let needed = segmentsNeeded(forPacketByteCount: packet.count)
            if !batch.isEmpty && segmentsInBatch + needed > 255 {
                granule += Int64(batch.count) * frameDuration48k
                out += makePage(sequence: pageSequence, granulePosition: granule, packets: batch, headerType: 0x00)
                pageSequence += 1
                batch = []
                segmentsInBatch = 0
            }
            batch.append(packet)
            segmentsInBatch += needed

            if index == packets.count - 1 {
                granule += Int64(batch.count) * frameDuration48k
                out += makePage(sequence: pageSequence, granulePosition: granule, packets: batch, headerType: 0x04)
                pageSequence += 1
                batch = []
            }
        }

        return out
    }

    // MARK: - Packets

    private func makeOpusHeadPacket() -> Data {
        var d = Data()
        d.append(contentsOf: Array("OpusHead".utf8))
        d.append(1) // version
        d.append(channelCount)
        appendLE(&d, preSkip)
        appendLE(&d, inputSampleRate)
        appendLE(&d, Int16(0)) // output gain, Q7.8, 0 = no adjustment
        d.append(0) // channel mapping family 0: mono/stereo, no mapping table
        return d
    }

    private func makeOpusTagsPacket() -> Data {
        var d = Data()
        d.append(contentsOf: Array("OpusTags".utf8))
        let vendor = Array("ProsioAudio".utf8)
        appendLE(&d, UInt32(vendor.count))
        d.append(contentsOf: vendor)
        appendLE(&d, UInt32(0)) // no user comments
        return d
    }

    // MARK: - Pages

    private func makePage(sequence: UInt32, granulePosition: Int64, packets: [Data], headerType: UInt8) -> Data {
        var segmentTable: [UInt8] = []
        var payload = Data()
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                segmentTable.append(255)
                remaining -= 255
            }
            segmentTable.append(UInt8(remaining))
            payload.append(packet)
        }
        precondition(segmentTable.count <= 255, "Ogg page segment table overflow (caller must batch packets)")

        var header = Data()
        header.append(contentsOf: Array("OggS".utf8))
        header.append(0) // stream structure version
        header.append(headerType)
        appendLE(&header, granulePosition)
        appendLE(&header, serial)
        appendLE(&header, sequence)
        appendLE(&header, UInt32(0)) // CRC placeholder, patched below
        header.append(UInt8(segmentTable.count))
        header.append(contentsOf: segmentTable)

        var page = header
        page.append(payload)

        let crc = OggCRC32.checksum(page)
        var crcData = Data()
        appendLE(&crcData, crc)
        page.replaceSubrange(22..<26, with: crcData)

        return page
    }

    // MARK: - Little-endian append helpers

    private func appendLE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendLE(_ data: inout Data, _ value: Int16) {
        appendLE(&data, UInt16(bitPattern: value))
    }

    private func appendLE(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private func appendLE(_ data: inout Data, _ value: Int64) {
        let unsigned = UInt64(bitPattern: value)
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: unsigned >> shift))
        }
    }
}
