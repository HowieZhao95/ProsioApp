import { currentBillingPeriod, modelRequestLimit } from "@/lib/entitlements";
import { getStore } from "@/lib/store";
import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { classifyIntent, type IntentDecision } from "@/lib/intent";
import { appContextSchema } from "@/lib/schemas";
import { RequestTimer } from "@/lib/timing";

// Node runtime; Jev itself is capped at 1.2s (lib/intent.ts) — 10s is ample headroom.
export const runtime = "nodejs";
export const maxDuration = 10;
export const dynamic = "force-dynamic";

const bodySchema = z.object({
  transcript: z.string().min(1).max(4000),
  hasSelection: z.boolean(),
  app: appContextSchema,
});

const UNAVAILABLE: Omit<IntentDecision, "latencyMs"> = { intent: null, confidence: null, source: "unavailable" };

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

  // classifyIntent never throws by design, but classifier failures must
  // never 5xx no matter what — defense in depth around it too.
  let decision: IntentDecision;
  try {
    decision = await classifyIntent({
      transcript: parsed.data.transcript,
      hasSelection: parsed.data.hasSelection,
      appName: parsed.data.app?.appName ?? null,
    });
  } catch {
    decision = { ...UNAVAILABLE, latencyMs: Math.round(timer.totalMs()) };
  }
  timer.mark("jev");

  console.log("[intent]", { userId: user.id, source: decision.source, intent: decision.intent, ...timer.toObject() });

  return Response.json(decision, { headers: { "Server-Timing": timer.toServerTimingHeader() } });
});
