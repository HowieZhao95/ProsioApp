import { currentBillingPeriod, modelRequestLimit } from "@/lib/entitlements";
import { getStore } from "@/lib/store";
import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { routeTranscript } from "@/lib/router";
import { RequestTimer } from "@/lib/timing";

export const runtime = "nodejs";
export const maxDuration = 10; // Jev is ~70-500ms; we cap our own wait at 1.5s (lib/router.ts) — 10s is ample headroom.
export const dynamic = "force-dynamic";

const MAX_TRANSCRIPT_LENGTH = 4000;
const MAX_VOCABULARY_TERMS = 1000;
const MAX_TERM_LENGTH = 100;

const bodySchema = z.object({
  localTranscript: z.string().min(1).max(MAX_TRANSCRIPT_LENGTH),
  vocabulary: z.array(z.string().max(MAX_TERM_LENGTH)).max(MAX_VOCABULARY_TERMS).default([]),
  languageHints: z.array(z.string().max(64)).max(16).default([]),
});

export const POST = withErrorHandling(async (req: Request) => {
  const timer = new RequestTimer();

  const user = await requireUser(req);
  timer.mark("auth");

  const json = await readJson(req);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid request body");
  }
  timer.mark("parse");
  await getStore().consumeModelRequest(user.id, currentBillingPeriod().periodStart, modelRequestLimit());

  const decision = await routeTranscript({
    transcript: parsed.data.localTranscript,
    vocabulary: parsed.data.vocabulary,
    languageHints: parsed.data.languageHints,
  });
  timer.mark("jev");

  console.log("[route]", { userId: user.id, reason: decision.reason, ...timer.toObject() });

  return Response.json(decision, { headers: { "Server-Timing": timer.toServerTimingHeader() } });
});
