import { z } from "zod";

export const evalCategorySchema = z.enum([
  "filler",
  "self-correction",
  "list",
  "code-switch",
  "names-jargon",
  "punctuation",
  "long-form",
]);
export type EvalCategory = z.infer<typeof evalCategorySchema>;

export const evalLanguageSchema = z.enum(["zh", "en", "mixed"]);
export type EvalLanguage = z.infer<typeof evalLanguageSchema>;

export const evalCaseSchema = z.object({
  id: z.string().min(1),
  category: evalCategorySchema,
  language: evalLanguageSchema,
  /** What the tester should say, including natural disfluencies. */
  script: z.string().min(1),
  /** Ideal clean SMART-mode output. */
  expected: z.string().min(1),
  /** Personal-dictionary terms to bias recognition with. */
  vocabulary: z.array(z.string()),
});
export type EvalCase = z.infer<typeof evalCaseSchema>;

export const evalCasesSchema = z.array(evalCaseSchema);

export type TranscribeMode = "smart" | "verbatim";

/** Cloud batch transcription transport. */
export type EvalTransport = "batch";

export interface EvalCaseResult {
  id: string;
  category: EvalCategory;
  language: EvalLanguage;
  mode: TranscribeMode;
  transport: EvalTransport;
  hasAudio: boolean;
  text: string;
  expected: string;
  cer: number;
  editDistance: number;
  /** Streaming only (transport "live"); null for batch. */
  timeToFirstPartialMs: number | null;
  /** Streaming only (transport "live"); null for batch. */
  timeToFinalAfterAudioEndMs: number | null;
  partialCount: number;
  /** Batch only (transport "batch"): wall-clock time of the whole transcribe() call. Null for live. */
  requestLatencyMs: number | null;
  heuristics: { name: string; passed: boolean; detail?: string }[];
  error?: string;
}
