// Minimal WAV (RIFF/PCM) reader. Only supports uncompressed PCM (fmt tag 1),
// which is what the eval README's ffmpeg recipe produces. Walks chunks
// generically so extra chunks (LIST, fact, ...) some encoders add don't
// break parsing.

export interface WavFile {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  /** Raw PCM sample bytes (the `data` chunk contents). */
  data: Buffer;
}

const PCM_FORMAT_TAG = 1;
const WAVE_FORMAT_EXTENSIBLE = 0xfffe;

export class WavParseError extends Error {}

export function parseWav(buffer: Buffer): WavFile {
  if (buffer.length < 12 || buffer.toString("ascii", 0, 4) !== "RIFF" || buffer.toString("ascii", 8, 12) !== "WAVE") {
    throw new WavParseError("Not a RIFF/WAVE file");
  }

  let offset = 12;
  let fmt: { formatTag: number; channels: number; sampleRate: number; bitsPerSample: number } | undefined;
  let data: Buffer | undefined;

  while (offset + 8 <= buffer.length) {
    const chunkId = buffer.toString("ascii", offset, offset + 4);
    const chunkSize = buffer.readUInt32LE(offset + 4);
    const bodyStart = offset + 8;
    const bodyEnd = Math.min(bodyStart + chunkSize, buffer.length);

    if (chunkId === "fmt ") {
      fmt = {
        formatTag: buffer.readUInt16LE(bodyStart),
        channels: buffer.readUInt16LE(bodyStart + 2),
        sampleRate: buffer.readUInt32LE(bodyStart + 4),
        bitsPerSample: buffer.readUInt16LE(bodyStart + 14),
      };
    } else if (chunkId === "data") {
      data = buffer.subarray(bodyStart, bodyEnd);
    }

    // Chunks are word-aligned: a chunk with an odd size has one padding byte.
    offset = bodyStart + chunkSize + (chunkSize % 2);
  }

  if (!fmt) throw new WavParseError("Missing fmt chunk");
  if (!data) throw new WavParseError("Missing data chunk");
  if (fmt.formatTag !== PCM_FORMAT_TAG && fmt.formatTag !== WAVE_FORMAT_EXTENSIBLE) {
    throw new WavParseError(`Unsupported WAV format tag ${fmt.formatTag}; expected PCM (1)`);
  }

  return {
    sampleRate: fmt.sampleRate,
    channels: fmt.channels,
    bitsPerSample: fmt.bitsPerSample,
    data,
  };
}

/**
 * Splits raw PCM16 sample data into ~`chunkMs` chunks, for real-time-paced
 * streaming to the transcription WebSocket. The last chunk may be shorter.
 */
export function chunkPcm16(data: Buffer, sampleRate: number, channels: number, chunkMs = 50): Buffer[] {
  const bytesPerFrame = 2 * channels; // 16-bit samples
  const framesPerChunk = Math.max(1, Math.round((sampleRate * chunkMs) / 1000));
  const bytesPerChunk = framesPerChunk * bytesPerFrame;

  const chunks: Buffer[] = [];
  for (let offset = 0; offset < data.length; offset += bytesPerChunk) {
    chunks.push(data.subarray(offset, Math.min(offset + bytesPerChunk, data.length)));
  }
  return chunks;
}
