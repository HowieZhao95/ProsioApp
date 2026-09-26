import { randomUUID } from "node:crypto";
import { signSessionToken } from "@/lib/auth";

export function jsonRequest(
  url: string,
  method: string,
  body?: unknown,
  headers: Record<string, string> = {}
): Request {
  return new Request(`http://localhost${url}`, {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export async function authedUser(email = `${randomUUID()}@example.com`) {
  const id = randomUUID();
  const token = await signSessionToken({ id, email });
  return { id, email, token, authHeader: { authorization: `Bearer ${token}` } };
}

/** Builds a minimal 16-bit PCM WAV file buffer, for tests. */
export function makeWav({
  sampleRate = 16000,
  channels = 1,
  bitsPerSample = 16,
  sampleCount = sampleRate, // 1 second of silence by default
}: {
  sampleRate?: number;
  channels?: number;
  bitsPerSample?: number;
  sampleCount?: number;
} = {}): Buffer {
  const dataBuf = Buffer.alloc(sampleCount * channels * (bitsPerSample / 8));

  const blockAlign = channels * (bitsPerSample / 8);
  const byteRate = sampleRate * blockAlign;

  const fmtBuf = Buffer.alloc(16);
  fmtBuf.writeUInt16LE(1, 0); // PCM
  fmtBuf.writeUInt16LE(channels, 2);
  fmtBuf.writeUInt32LE(sampleRate, 4);
  fmtBuf.writeUInt32LE(byteRate, 8);
  fmtBuf.writeUInt16LE(blockAlign, 12);
  fmtBuf.writeUInt16LE(bitsPerSample, 14);

  const u32 = (n: number) => {
    const b = Buffer.alloc(4);
    b.writeUInt32LE(n, 0);
    return b;
  };

  const body = Buffer.concat([
    Buffer.from("fmt "),
    u32(fmtBuf.length),
    fmtBuf,
    Buffer.from("data"),
    u32(dataBuf.length),
    dataBuf,
  ]);

  return Buffer.concat([Buffer.from("RIFF"), u32(4 + body.length), Buffer.from("WAVE"), body]);
}

export function makeWavBase64(opts: Parameters<typeof makeWav>[0] = {}): string {
  return makeWav(opts).toString("base64");
}

// --- Minimal Ogg/Opus test fixture (P1.2) ----------------------------------
//
// Builds a structurally-valid (but not decodable — the "audio" packet is a
// dummy byte, not real Opus data) Ogg/Opus file: an OpusHead page, an
// OpusTags page, and one more page whose granule position encodes the
// requested duration. lib/ogg-opus.ts's parser only reads container
// structure (page/segment layout, the OpusHead packet's channel
// count/pre-skip, and the final page's granule position) — it never
// decodes audio — so this is sufficient for exercising it in tests.

function oggPage({
  granulePosition,
  serial = 1,
  sequence,
  headerType = 0,
  packets,
}: {
  granulePosition: bigint;
  serial?: number;
  sequence: number;
  headerType?: number;
  packets: Buffer[];
}): Buffer {
  const segmentTable: number[] = [];
  for (const packet of packets) {
    let remaining = packet.length;
    while (remaining >= 255) {
      segmentTable.push(255);
      remaining -= 255;
    }
    segmentTable.push(remaining);
  }

  const header = Buffer.alloc(27);
  header.write("OggS", 0, "ascii");
  header.writeUInt8(0, 4); // stream structure version
  header.writeUInt8(headerType, 5);
  header.writeBigInt64LE(granulePosition, 6);
  header.writeUInt32LE(serial, 14);
  header.writeUInt32LE(sequence, 18);
  header.writeUInt32LE(0, 22); // CRC32 — not validated by lib/ogg-opus.ts's parser
  header.writeUInt8(segmentTable.length, 26);

  return Buffer.concat([header, Buffer.from(segmentTable), ...packets]);
}

/** Builds an OpusHead identification header packet (RFC 7845 §5.1), 19 bytes (no channel mapping table). */
function makeOpusHead({ channelCount = 1, preSkip = 312 }: { channelCount?: number; preSkip?: number } = {}): Buffer {
  const packet = Buffer.alloc(19);
  packet.write("OpusHead", 0, "ascii");
  packet.writeUInt8(1, 8); // version
  packet.writeUInt8(channelCount, 9);
  packet.writeUInt16LE(preSkip, 10);
  packet.writeUInt32LE(48000, 12); // input sample rate (informational)
  packet.writeInt16LE(0, 16); // output gain
  packet.writeUInt8(0, 18); // channel mapping family
  return packet;
}

/** Builds a minimal Ogg/Opus file buffer with a computable duration, for tests. */
export function makeOggOpus({
  durationSeconds = 1,
  channelCount = 1,
  preSkip = 312,
}: {
  durationSeconds?: number;
  channelCount?: number;
  preSkip?: number;
} = {}): Buffer {
  const page0 = oggPage({ granulePosition: 0n, sequence: 0, headerType: 0x02, packets: [makeOpusHead({ channelCount, preSkip })] });
  const page1 = oggPage({
    granulePosition: 0n,
    sequence: 1,
    packets: [Buffer.concat([Buffer.from("OpusTags", "ascii"), Buffer.alloc(8)])],
  });
  const totalSamples = BigInt(preSkip) + BigInt(Math.round(durationSeconds * 48000));
  const page2 = oggPage({ granulePosition: totalSamples, sequence: 2, headerType: 0x04, packets: [Buffer.from([0xfc])] });

  return Buffer.concat([page0, page1, page2]);
}

export function makeOggOpusBase64(opts: Parameters<typeof makeOggOpus>[0] = {}): string {
  return makeOggOpus(opts).toString("base64");
}
