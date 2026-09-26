// --- Minimal Ogg/Opus container parser (P1.2) ------------------------------
//
// docs/P1.2-AUDIO-ROUTING.md §1/§3: the client now uploads Ogg-container,
// Opus-encoded audio (RFC 7845) instead of WAV, for a ~16x size reduction
// at identical transcription quality (coordinator-verified live against
// Gemini batch transcribe). `POST /api/transcribe` needs `durationSeconds`
// for usage metering regardless of upload format, so this parses just
// enough of the Ogg container to compute it — no audio decoding.
//
// We do NOT need to tell Gemini the media type explicitly: `transcribe()`
// (lib/gateway.ts's `transcribeBatch`) auto-sniffs "audio/ogg" from the
// "OggS" magic bytes via @ai-sdk/provider-utils' `detectMediaType` (see
// audioMediaTypeSignatures in its source) — confirmed present in the
// installed `ai`/`@ai-sdk/provider-utils` versions. So the whole Ogg file's
// bytes are passed to `transcribeBatch` exactly like a WAV file's bytes are
// today; nothing in lib/gateway.ts needs to change for this format.
//
// Format reference (RFC 3533 "Ogg" + RFC 7845 "Ogg Opus"):
// - Each Ogg page: "OggS" (4B) + version (1B) + header_type (1B) +
//   granule_position (8B LE, int64) + serial (4B LE) + sequence (4B LE) +
//   CRC32 (4B LE, NOT validated here — we only need structure, not
//   integrity checking) + page_segments (1B) + segment_table
//   (page_segments bytes, "lacing values") + page data (segment_table's
//   values summed).
// - A packet's length is encoded as a run of lacing values: 255 means "add
//   255 bytes and continue", any value < 255 ends the packet at that many
//   more bytes. Our own encoder (OggOpusWriter, Swift) never splits a
//   packet across pages for the tiny header packets, so reading a page's
//   first packet is always safe without cross-page continuation handling.
// - The very first page's very first packet must be an "OpusHead"
//   identification header (RFC 7845 §5.1): 8-byte magic, then version(1B),
//   channel count(1B), pre-skip(2B LE), input sample rate(4B LE), output
//   gain(2B LE), channel mapping family(1B), ... — we only need
//   channel-count and pre-skip.
// - Duration: Opus granule positions are always in units of 1/48000s
//   (RFC 7845 §4), regardless of the encoder's actual sample rate. The
//   final page's granule position, minus the identification header's
//   pre-skip, is the total sample count at 48kHz; dividing by 48000 gives
//   the duration in seconds.

export class OggOpusParseError extends Error {}

export interface OggOpusInfo {
  durationSeconds: number;
  channelCount: number;
  preSkipSamples: number;
}

const OGGS_MAGIC = Buffer.from("OggS", "ascii");
const OPUSHEAD_MAGIC = Buffer.from("OpusHead", "ascii");
const OGG_PAGE_HEADER_SIZE = 27; // up to and including the page_segments byte

/** Length of the first packet in a page, per the page's segment table. */
function firstPacketLength(segmentTable: Buffer): number {
  let length = 0;
  for (const lacingValue of segmentTable) {
    length += lacingValue;
    if (lacingValue < 255) break; // packet ends at the first lacing value < 255
  }
  return length;
}

/**
 * Parses just enough of an Ogg/Opus file to compute its duration and
 * channel count. Throws `OggOpusParseError` for anything structurally
 * invalid — callers should map that to a 400 `bad_request` (this is a
 * content problem, distinct from an unrecognized `audioFormat` value,
 * which is a 415).
 */
export function parseOggOpus(buf: Buffer): OggOpusInfo {
  if (buf.length < OGG_PAGE_HEADER_SIZE || !buf.subarray(0, 4).equals(OGGS_MAGIC)) {
    throw new OggOpusParseError("not a valid Ogg file (missing 'OggS' capture pattern)");
  }

  let offset = 0;
  let pageIndex = 0;
  let lastGranulePosition = 0n;
  let channelCount: number | null = null;
  let preSkipSamples: number | null = null;

  while (offset < buf.length) {
    if (offset + OGG_PAGE_HEADER_SIZE > buf.length || !buf.subarray(offset, offset + 4).equals(OGGS_MAGIC)) {
      throw new OggOpusParseError(`expected an Ogg page ("OggS") at byte ${offset}`);
    }

    const granulePosition = buf.readBigInt64LE(offset + 6);
    const numSegments = buf.readUInt8(offset + 26);
    const segmentTableStart = offset + OGG_PAGE_HEADER_SIZE;
    if (segmentTableStart + numSegments > buf.length) {
      throw new OggOpusParseError("truncated Ogg segment table");
    }
    const segmentTable = buf.subarray(segmentTableStart, segmentTableStart + numSegments);
    const pageDataStart = segmentTableStart + numSegments;
    const pageDataLength = segmentTable.reduce((sum, v) => sum + v, 0);
    const pageDataEnd = pageDataStart + pageDataLength;
    if (pageDataEnd > buf.length) {
      throw new OggOpusParseError("truncated Ogg page data");
    }

    if (pageIndex === 0) {
      const packetLength = firstPacketLength(segmentTable);
      const packet = buf.subarray(pageDataStart, pageDataStart + packetLength);
      if (packetLength < 19 || !packet.subarray(0, 8).equals(OPUSHEAD_MAGIC)) {
        throw new OggOpusParseError("first Ogg page's first packet is not an OpusHead identification header");
      }
      channelCount = packet.readUInt8(9);
      preSkipSamples = packet.readUInt16LE(10);
    }

    lastGranulePosition = granulePosition;
    offset = pageDataEnd;
    pageIndex++;
  }

  if (channelCount === null || preSkipSamples === null) {
    throw new OggOpusParseError("no Ogg pages found");
  }

  const totalSamples = lastGranulePosition - BigInt(preSkipSamples);
  if (totalSamples < 0n) {
    throw new OggOpusParseError("invalid Opus granule position (before the identification header's pre-skip)");
  }

  return {
    durationSeconds: Number(totalSamples) / 48000,
    channelCount,
    preSkipSamples,
  };
}
