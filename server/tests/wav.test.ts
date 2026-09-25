import { describe, expect, it } from "vitest";
import { chunkPcm16, parseWav, WavParseError } from "@/lib/wav";

/** Builds a minimal 16-bit PCM WAV file buffer for testing. */
function makeWav({
  sampleRate = 24000,
  channels = 1,
  bitsPerSample = 16,
  samples,
}: {
  sampleRate?: number;
  channels?: number;
  bitsPerSample?: number;
  samples: number[];
}): Buffer {
  const dataBuf = Buffer.alloc(samples.length * 2);
  samples.forEach((s, i) => dataBuf.writeInt16LE(s, i * 2));

  const blockAlign = channels * (bitsPerSample / 8);
  const byteRate = sampleRate * blockAlign;

  const fmtBuf = Buffer.alloc(16);
  fmtBuf.writeUInt16LE(1, 0); // PCM
  fmtBuf.writeUInt16LE(channels, 2);
  fmtBuf.writeUInt32LE(sampleRate, 4);
  fmtBuf.writeUInt32LE(byteRate, 8);
  fmtBuf.writeUInt16LE(blockAlign, 12);
  fmtBuf.writeUInt16LE(bitsPerSample, 14);

  const chunks = [
    Buffer.from("fmt "),
    u32(fmtBuf.length),
    fmtBuf,
    Buffer.from("data"),
    u32(dataBuf.length),
    dataBuf,
  ];
  const body = Buffer.concat(chunks);

  return Buffer.concat([Buffer.from("RIFF"), u32(4 + body.length), Buffer.from("WAVE"), body]);
}

function u32(n: number): Buffer {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n, 0);
  return b;
}

describe("parseWav", () => {
  it("parses sample rate, channels, bit depth, and PCM data", () => {
    const samples = [0, 100, -100, 32767, -32768];
    const wav = parseWav(makeWav({ samples }));
    expect(wav.sampleRate).toBe(24000);
    expect(wav.channels).toBe(1);
    expect(wav.bitsPerSample).toBe(16);
    expect(wav.data.length).toBe(samples.length * 2);
    expect(wav.data.readInt16LE(0)).toBe(0);
    expect(wav.data.readInt16LE(2)).toBe(100);
    expect(wav.data.readInt16LE(6)).toBe(32767);
  });

  it("rejects a non-RIFF buffer", () => {
    expect(() => parseWav(Buffer.from("not a wav file at all"))).toThrow(WavParseError);
  });

  it("tolerates an extra chunk before fmt/data (e.g. LIST)", () => {
    const listBody = Buffer.from("INFOsome metadata"); // odd length: exercises RIFF word-alignment padding
    const pad = listBody.length % 2 === 1 ? Buffer.from([0]) : Buffer.alloc(0);
    const listChunk = Buffer.concat([Buffer.from("LIST"), u32(listBody.length), listBody, pad]);
    const base = makeWav({ samples: [1, 2, 3] });
    // Splice the LIST chunk in right after the WAVE tag.
    const withList = Buffer.concat([base.subarray(0, 12), listChunk, base.subarray(12)]);
    const riffSize = withList.length - 8;
    withList.writeUInt32LE(riffSize, 4);

    const wav = parseWav(withList);
    expect(wav.data.length).toBe(6);
  });
});

describe("chunkPcm16", () => {
  it("splits PCM data into ~50ms chunks at 24kHz mono", () => {
    // 24000 Hz * 0.05s * 2 bytes = 2400 bytes/chunk; make 3 full chunks + a partial one.
    const totalBytes = 2400 * 3 + 800;
    const data = Buffer.alloc(totalBytes);
    const chunks = chunkPcm16(data, 24000, 1, 50);
    expect(chunks).toHaveLength(4);
    expect(chunks[0]!.length).toBe(2400);
    expect(chunks[1]!.length).toBe(2400);
    expect(chunks[2]!.length).toBe(2400);
    expect(chunks[3]!.length).toBe(800);
  });

  it("handles empty data", () => {
    expect(chunkPcm16(Buffer.alloc(0), 24000, 1, 50)).toEqual([]);
  });
});
