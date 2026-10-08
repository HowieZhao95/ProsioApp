import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { findMeetingJob } from "@/lib/meetings/db";
import { PART_SIZE, signPart } from "@/lib/meetings/storage";

export const dynamic = "force-dynamic";
const bodySchema = z.object({ partNumber: z.number().int().min(1).max(10_000) });

export const POST = withErrorHandling(async (req: Request, context: { params: Promise<{ id: string }> }) => {
  const user = await requireUser(req);
  const { id } = await context.params;
  if (!z.string().uuid().safeParse(id).success) throw new ApiError("bad_request", "Invalid job ID");
  const parsed = bodySchema.safeParse(await readJson(req));
  if (!parsed.success) throw new ApiError("bad_request", "Invalid part number");
  const job = await findMeetingJob(id, user.id);
  if (job.status !== "uploading" || !job.upload_id) throw new ApiError("conflict", "Meeting is not uploading");
  if (new Date(job.expires_at).getTime() <= Date.now()) throw new ApiError("conflict", "Meeting upload expired");
  const count = Math.ceil(Number(job.expected_bytes) / PART_SIZE);
  if (parsed.data.partNumber > count) throw new ApiError("bad_request", "Part exceeds expected file size");
  return Response.json({ url: await signPart(job.object_key, job.upload_id, parsed.data.partNumber) });
});
