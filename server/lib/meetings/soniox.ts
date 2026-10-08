import { ApiError } from "@/lib/errors";

const BASE = "https://api.soniox.com/v1";

export interface SonioxToken {
  text: string;
  start_ms?: number | null;
  end_ms?: number | null;
  speaker?: string | null;
  language?: string | null;
}

function key(): string {
  const value = process.env.SONIOX_API_KEY;
  if (!value) throw new ApiError("unavailable", "Soniox is not configured");
  return value;
}

async function request(path: string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${key()}`, ...(init.body ? { "Content-Type": "application/json" } : {}) },
    signal: AbortSignal.timeout(20_000),
  });
  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError("upstream_error", `Soniox HTTP ${response.status}`);
  return body;
}

export async function createTranscription(audioURL: string, meetingID: string, languageHints: string[]): Promise<string> {
  const body = await request("/transcriptions", { method: "POST", body: JSON.stringify({
    model: "stt-async-v5", audio_url: audioURL,
    enable_speaker_diarization: true, enable_language_identification: true,
    language_hints: languageHints.map((value) => value.split("-")[0]).filter(Boolean).slice(0, 5),
    client_reference_id: meetingID,
  }) });
  if (!body || typeof body !== "object" || !("id" in body) || typeof body.id !== "string") {
    throw new ApiError("upstream_error", "Soniox did not return a transcription ID");
  }
  return body.id;
}

export async function getTranscription(id: string): Promise<{ status: string; error_message?: string; audio_duration_ms?: number }> {
  const body = await request(`/transcriptions/${encodeURIComponent(id)}`);
  if (!body || typeof body !== "object" || !("status" in body) || typeof body.status !== "string") {
    throw new ApiError("upstream_error", "Invalid Soniox job status");
  }
  return body as { status: string; error_message?: string; audio_duration_ms?: number };
}

export async function getTranscript(id: string): Promise<{ text: string; tokens: SonioxToken[] }> {
  const body = await request(`/transcriptions/${encodeURIComponent(id)}/transcript`);
  if (!body || typeof body !== "object" || !("tokens" in body) || !Array.isArray(body.tokens)) {
    throw new ApiError("upstream_error", "Invalid Soniox transcript");
  }
  return body as { text: string; tokens: SonioxToken[] };
}

export async function removeTranscription(id: string) {
  try { await request(`/transcriptions/${encodeURIComponent(id)}`, { method: "DELETE" }); }
  catch { /* Retry through maintenance if provider deletion fails. */ }
}
