import { ApiError } from "./errors";

/** Bounds actual bytes (including chunked requests); never trusts Content-Length. */
export async function readJson(req: Request, maxBytes = 512 * 1024): Promise<unknown> {
  if (!req.body) return null;
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new ApiError("payload_too_large", "Request body too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  try { return JSON.parse(Buffer.concat(chunks, length).toString("utf8")); }
  catch { return null; }
}
