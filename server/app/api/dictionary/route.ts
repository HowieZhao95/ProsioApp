import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { getStore } from "@/lib/store";

export const dynamic = "force-dynamic";

const MAX_ENTRIES = 1000;
const MAX_TERM_LENGTH = 100;

const entrySchema = z.object({
  id: z.string().uuid(),
  term: z.string().min(1).max(MAX_TERM_LENGTH),
  note: z.string().nullable(),
  createdAt: z.string().refine((s) => !Number.isNaN(Date.parse(s)), "createdAt must be an ISO-8601 date"),
  updatedAt: z.string().refine((s) => !Number.isNaN(Date.parse(s)), "updatedAt must be an ISO-8601 date"),
});

const bodySchema = z.object({
  entries: z.array(entrySchema).max(MAX_ENTRIES, `At most ${MAX_ENTRIES} entries`),
});

export const GET = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);
  const store = getStore();
  const entries = await store.getDictionary(user.id);
  return Response.json({ entries });
});

export const PUT = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);

  const json = await readJson(req);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid dictionary payload");
  }

  const store = getStore();
  const entries = await store.putDictionary(user.id, parsed.data.entries);
  return Response.json({ entries });
});
