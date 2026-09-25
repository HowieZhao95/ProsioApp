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
