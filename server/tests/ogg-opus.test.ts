import { describe, expect, it } from "vitest";
import { OggOpusParseError, parseOggOpus } from "@/lib/ogg-opus";
import { makeOggOpus } from "./helpers";

describe("parseOggOpus", () => {
  it("computes duration from the final page's granule position minus pre-skip", () => {
    const info = parseOggOpus(makeOggOpus({ durationSeconds: 3.7 }));
    expect(info.durationSeconds).toBeCloseTo(3.7, 2);
    expect(info.channelCount).toBe(1);
  });

  it("reports the channel count from the OpusHead packet", () => {
    const info = parseOggOpus(makeOggOpus({ channelCount: 2 }));
    expect(info.channelCount).toBe(2);
  });

  it("handles a non-default pre-skip", () => {
    const info = parseOggOpus(makeOggOpus({ durationSeconds: 2, preSkip: 600 }));
    expect(info.durationSeconds).toBeCloseTo(2, 2);
  });

  it("throws OggOpusParseError for bytes that aren't Ogg at all", () => {
    expect(() => parseOggOpus(Buffer.from("this is not ogg at all"))).toThrow(OggOpusParseError);
  });

  it("throws OggOpusParseError for a truncated file", () => {
    const full = makeOggOpus({ durationSeconds: 1 });
    expect(() => parseOggOpus(full.subarray(0, 40))).toThrow(OggOpusParseError);
  });

  it("throws OggOpusParseError when the first packet isn't an OpusHead", () => {
    // A page whose first packet doesn't start with "OpusHead".
    const header = Buffer.alloc(27);
    header.write("OggS", 0, "ascii");
    header.writeUInt8(0, 4);
    header.writeUInt8(0x02, 5);
    header.writeBigInt64LE(0n, 6);
    header.writeUInt32LE(1, 14);
    header.writeUInt32LE(0, 18);
    header.writeUInt32LE(0, 22);
    const packet = Buffer.alloc(19); // 19 zero bytes, not "OpusHead"
    header.writeUInt8(1, 26);
    const buf = Buffer.concat([header, Buffer.from([19]), packet]);
    expect(() => parseOggOpus(buf)).toThrow(OggOpusParseError);
  });
});
