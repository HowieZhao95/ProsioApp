import Foundation
import Testing
@testable import ProsioAudio

@Suite struct OggOpusEncoderTests {
    static let sampleRate: Double = 16_000
    static let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    static func tone(seconds: Double, amplitude: Double = 0.5, frequency: Double = 220, sampleRate: Double = sampleRate) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let value = amplitude * sin(2 * .pi * frequency * t)
            return Int16(clamping: Int((value * Double(Int16.max)).rounded()))
        }
    }

    // MARK: - Structural checks (no ffmpeg needed)

    @Test func encode_emptyInput_throws() {
        let encoder = OggOpusEncoder()
        #expect(throws: OggOpusEncoderError.self) {
            _ = try encoder.encode(pcm16: [Int16](), sampleRate: Self.sampleRate)
        }
    }

    @Test func encode_producesWellFormedOggContainer() throws {
        let encoder = OggOpusEncoder()
        let samples = Self.tone(seconds: 2)
        let data = try encoder.encode(pcm16: samples, sampleRate: Self.sampleRate)

        #expect(data.count > 4)
        #expect(data.prefix(4) == Data("OggS".utf8))

        // Walk every page, verifying capture pattern + CRC, and find OpusHead/OpusTags + EOS flag.
        var offset = data.startIndex
        var sawHead = false
        var sawTags = false
        var sawEOS = false
        var pageCount = 0

        while offset < data.endIndex {
            #expect(data[offset..<offset + 4] == Data("OggS".utf8))
            let headerType = data[offset + 5]
            let segmentCount = Int(data[offset + 26])
            let segmentTableStart = offset + 27
            let segmentTable = data[segmentTableStart..<segmentTableStart + segmentCount]
            let payloadLength = segmentTable.reduce(0) { $0 + Int($1) }
            let payloadStart = segmentTableStart + segmentCount
            let pageEnd = payloadStart + payloadLength

            var pageForCRC = data[offset..<pageEnd]
            let storedCRC = data.subdata(in: (offset + 22)..<(offset + 26)).withUnsafeBytes { $0.load(as: UInt32.self) }
            pageForCRC.replaceSubrange((offset + 22)..<(offset + 26), with: Data([0, 0, 0, 0]))
            #expect(OggCRC32.checksum(Data(pageForCRC)) == storedCRC, "CRC mismatch on page \(pageCount)")

            if headerType & 0x02 != 0 {
                let packetStart = payloadStart
                #expect(data[packetStart..<packetStart + 8] == Data("OpusHead".utf8))
                sawHead = true
            } else if !sawTags {
                let packetStart = payloadStart
                if data[packetStart..<packetStart + 8] == Data("OpusTags".utf8) {
                    sawTags = true
                }
            }
            if headerType & 0x04 != 0 { sawEOS = true }

            pageCount += 1
            offset = pageEnd
        }

        #expect(sawHead)
        #expect(sawTags)
        #expect(sawEOS)
        #expect(pageCount >= 3) // head + tags + at least one audio page
    }

    @Test func encode_dataOverload_matchesArrayOverload() throws {
        let encoder = OggOpusEncoder()
        let samples = Self.tone(seconds: 1)
        let data = int16SamplesToLittleEndianDataForTests(samples)

        // Both should succeed and produce structurally valid (if not byte-identical, due to the
        // random Ogg serial number) containers.
        let a = try encoder.encode(pcm16: samples, sampleRate: Self.sampleRate)
        let b = try encoder.encode(pcm16: data, sampleRate: Self.sampleRate)
        #expect(a.prefix(4) == Data("OggS".utf8))
        #expect(b.prefix(4) == Data("OggS".utf8))
    }

    // MARK: - ffmpeg round trip (skipped if ffmpeg isn't installed)

    private static func ffmpegAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    private static func decodePCM16(oggData: Data) throws -> [Int16] {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ogg")
        try oggData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-v", "error", "-i", tempURL.path, "-f", "s16le", "-ar", "16000", "-ac", "1", "-"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "ffmpeg failed: \(String(data: errData, encoding: .utf8) ?? "")")
        #expect(errData.isEmpty, "ffmpeg reported errors: \(String(data: errData, encoding: .utf8) ?? "")")

        return int16SamplesFromLittleEndianDataForTests(outData)
    }

    @Test func roundTrip_durationWithin40ms_ffmpegDecodesCleanly() throws {
        try #require(Self.ffmpegAvailable(), "ffmpeg not installed at \(Self.ffmpegPath) -- skipping round-trip test")

        let encoder = OggOpusEncoder()
        let inputSeconds = 5.0
        let samples = Self.tone(seconds: inputSeconds, amplitude: 0.4)
        let oggData = try encoder.encode(pcm16: samples, sampleRate: Self.sampleRate)

        let decoded = try Self.decodePCM16(oggData: oggData)
        let decodedSeconds = Double(decoded.count) / Self.sampleRate

        #expect(abs(decodedSeconds - inputSeconds) <= 0.04, "decoded \(decodedSeconds)s vs input \(inputSeconds)s")

        // SNR-ish sanity: decoded energy should be in the same ballpark as the input's (Opus at
        // 20kbps on a clean tone should be close to lossless-sounding).
        let inputRMS = rmsForTests(samples)
        let decodedRMS = rmsForTests(decoded)
        #expect(inputRMS > 0)
        let ratio = Double(decodedRMS) / Double(inputRMS)
        #expect(ratio > 0.5 && ratio < 1.8, "decoded RMS \(decodedRMS) too far from input RMS \(inputRMS)")
    }

    @Test func roundTrip_shortClip() throws {
        try #require(Self.ffmpegAvailable(), "ffmpeg not installed -- skipping")

        let encoder = OggOpusEncoder()
        let inputSeconds = 0.5
        let samples = Self.tone(seconds: inputSeconds)
        let oggData = try encoder.encode(pcm16: samples, sampleRate: Self.sampleRate)
        let decoded = try Self.decodePCM16(oggData: oggData)
        let decodedSeconds = Double(decoded.count) / Self.sampleRate

        #expect(abs(decodedSeconds - inputSeconds) <= 0.04)
    }

    // MARK: - Benchmark (informational; always runs, just prints)

    @Test func benchmark_twentySecondsOfAudio() throws {
        let encoder = OggOpusEncoder()
        let samples = Self.tone(seconds: 20)

        let clock = ContinuousClock()
        let start = clock.now
        let data = try encoder.encode(pcm16: samples, sampleRate: Self.sampleRate)
        let elapsed = clock.now - start

        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("[OggOpusEncoder benchmark] 20s @16kHz mono -> \(data.count) bytes in \(ms) ms")
        #expect(data.count > 0)
    }
}

func rmsForTests(_ samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples {
        let n = Double(s) / Double(Int16.max)
        sum += n * n
    }
    return Float((sum / Double(samples.count)).squareRoot())
}
