import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { ALLOWED_TRANSCRIBE_MODELS, isAllowedTranscribeModel, mintTranscribeToken } from "@/lib/gateway";
import { getStore } from "@/lib/store";

export const dynamic = "force-dynamic";

const DEFAULT_MODEL = ALLOWED_TRANSCRIBE_MODELS[0];

const bodySchema = z.object({
  model: z.string().optional(),
});

export const POST = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);

  const json = await req.json().catch(() => ({}));
  const parsed = bodySchema.safeParse(json ?? {});
  if (!parsed.success) {
    throw new ApiError("bad_request", "Body must be { model?: string }");
  }
  const model = parsed.data.model ?? DEFAULT_MODEL;
  if (!isAllowedTranscribeModel(model)) {
    throw new ApiError("bad_request", `Model "${model}" is not allow-listed`);
  }

  const store = getStore();
  const entitlement = await getEntitlement(user.id);
  const { periodStart, periodEnd } = currentBillingPeriod();
  const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);
  if (audioSecondsUsed >= entitlement.audioSecondsLimit) {
    throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
  }

  let minted;
  try {
    minted = await mintTranscribeToken(model);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Gateway request failed";
    throw new ApiError("upstream_error", `Failed to mint transcription token: ${message}`);
  }

  return Response.json(minted);
});
