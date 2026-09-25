import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { getStore } from "@/lib/store";

export const dynamic = "force-dynamic";

const bodySchema = z.object({
  sessionID: z.string().uuid(),
  engineID: z.string().min(1),
  audioSeconds: z.number().finite().nonnegative(),
  startedAt: z.string().refine((s) => !Number.isNaN(Date.parse(s)), "startedAt must be an ISO-8601 date"),
});

export const POST = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);

  const json = await req.json().catch(() => null);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid usage report");
  }

  const store = getStore();
  await store.recordUsage(user.id, parsed.data);

  return new Response(null, { status: 204 });
});

export const GET = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);

  const store = getStore();
  const entitlement = await getEntitlement(user.id);
  const { periodStart, periodEnd } = currentBillingPeriod();
  const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);

  return Response.json({
    periodStart: periodStart.toISOString(),
    periodEnd: periodEnd.toISOString(),
    audioSecondsUsed,
    audioSecondsLimit: entitlement.audioSecondsLimit,
  });
});
