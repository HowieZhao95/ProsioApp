import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { findMeetingJob, meetingSQL, releaseMeetingJob } from "@/lib/meetings/db";
import { completeUpload, PART_SIZE, removeUpload, signedReadURL, uploadedSize } from "@/lib/meetings/storage";
import { createTranscription } from "@/lib/meetings/soniox";
import { removeTranscription } from "@/lib/meetings/soniox";

export const dynamic = "force-dynamic";
export const maxDuration = 60;
const bodySchema = z.object({ parts: z.array(z.object({
  ETag: z.string().min(1).max(200), PartNumber: z.number().int().min(1),
})).min(1).max(10_000) });

export const POST = withErrorHandling(async (req: Request, context: { params: Promise<{ id: string }> }) => {
  const user = await requireUser(req);
  const { id } = await context.params;
  if (!z.string().uuid().safeParse(id).success) throw new ApiError("bad_request", "Invalid job ID");
  const parsed = bodySchema.safeParse(await readJson(req));
  if (!parsed.success) throw new ApiError("bad_request", "Invalid uploaded parts");
  const job = await findMeetingJob(id, user.id);
  if (job.status === "submitted" || job.status === "completed") return Response.json({ status: job.status });
  if (job.status !== "uploading" || !job.upload_id) throw new ApiError("conflict", "Meeting is not uploading");
  if (new Date(job.expires_at).getTime() <= Date.now()) throw new ApiError("conflict", "Meeting upload expired");
  const parts = parsed.data.parts;
  const expectedCount = Math.ceil(Number(job.expected_bytes) / PART_SIZE);
  if (parts.length !== expectedCount || parts.some((part, index) => part.PartNumber !== index + 1)) {
    throw new ApiError("bad_request", "Incomplete uploaded parts");
  }
  const sql = meetingSQL();
  const claimed = await sql`UPDATE meeting_jobs SET status = 'submitting', updated_at = now()
                            WHERE id = ${id}::uuid AND user_id = ${user.id}::uuid AND status = 'uploading'
                              AND expires_at > now()
                            RETURNING id`;
  if (!claimed[0]) throw new ApiError("conflict", "Meeting submission is already in progress");
  try {
    await completeUpload(job.object_key, job.upload_id, parts);
    if (await uploadedSize(job.object_key) !== Number(job.expected_bytes)) {
      throw new ApiError("bad_request", "Uploaded audio size differs from reservation");
    }
    const audioURL = await signedReadURL(job.object_key);
    const sonioxID = await createTranscription(audioURL, id, job.language_hints);
    const stored = await sql`UPDATE meeting_jobs SET status = 'submitted', soniox_id = ${sonioxID},
              upload_id = NULL, expires_at = now() + interval '7 days', updated_at = now()
              WHERE id = ${id}::uuid AND user_id = ${user.id}::uuid AND status = 'submitting'
              RETURNING id`;
    if (!stored[0]) {
      await removeTranscription(sonioxID);
      throw new ApiError("conflict", "Meeting was cancelled during submission");
    }
    return Response.json({ status: "submitted" });
  } catch (error) {
    await releaseMeetingJob(id, user.id, "failed", "provider_or_upload_failed");
    await removeUpload(job.object_key, job.upload_id);
    throw error;
  }
});
