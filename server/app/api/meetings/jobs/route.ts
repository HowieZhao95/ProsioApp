import { readJson } from "@/lib/request-body";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { findMeetingJob, meetingSQL } from "@/lib/meetings/db";
import { beginUpload, PART_SIZE } from "@/lib/meetings/storage";

export const dynamic = "force-dynamic";

const bodySchema = z.object({
  meetingID: z.string().uuid(),
  durationSeconds: z.number().finite().positive().max(18_000),
  bytes: z.number().int().positive().max(2_000_000_000),
  languageHints: z.array(z.string().max(20)).max(5).default([]),
});

export const POST = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);
  // durationSeconds is client metadata. Until uploaded audio duration is verified
  // before inference, enabling this route publicly would allow quota/cost bypass.
  if (process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production") {
    throw new ApiError("unavailable", "Cloud meetings require verified upload duration before public release");
  }
  if (!process.env.SONIOX_API_KEY || !process.env.S3_BUCKET || !process.env.DATABASE_URL) {
    throw new ApiError("unavailable", "Meeting cloud transcription is not configured");
  }
  const parsed = bodySchema.safeParse(await readJson(req));
  if (!parsed.success) throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid meeting");
  const { meetingID, durationSeconds, bytes, languageHints } = parsed.data;
  const entitlement = await getEntitlement(user.id);
  const { periodStart, periodEnd } = currentBillingPeriod();
  const key = `meetings/${user.id}/${meetingID}/recognition.m4a`;
  const sql = meetingSQL();
  let reservation;
  try {
    reservation = await sql`SELECT * FROM reserve_meeting_job(
      ${meetingID}::uuid, ${user.id}::uuid, ${periodStart.toISOString()}::timestamptz,
      ${periodEnd.toISOString()}::timestamptz, ${durationSeconds},
      ${entitlement.audioSecondsLimit}, ${bytes}, ${key}, ${languageHints}::text[])`;
  } catch (error) {
    if (error instanceof Error && error.message.includes("quota_exceeded")) {
      throw new ApiError("quota_exceeded", "Meeting cloud quota is exhausted");
    }
    throw error;
  }
  const row = reservation[0] as { was_created: boolean; job_status: string } | undefined;
  if (!row) throw new ApiError("upstream_error", "Unable to reserve meeting quota");
  if (!row.was_created) {
    const existing = await findMeetingJob(meetingID, user.id);
    if (Number(existing.expected_bytes) !== bytes) {
      throw new ApiError("conflict", "Meeting ID already belongs to a different recording");
    }
    if (row.job_status === "reserving") throw new ApiError("conflict", "Meeting upload is being prepared; retry shortly");
    return Response.json({ jobID: meetingID, status: row.job_status, partSize: PART_SIZE });
  }
  try {
    const uploadID = await beginUpload(key);
    await sql`UPDATE meeting_jobs SET upload_id = ${uploadID}, status = 'uploading', updated_at = now()
              WHERE id = ${meetingID}::uuid AND user_id = ${user.id}::uuid AND status = 'reserving'`;
    return Response.json({ jobID: meetingID, status: "uploading", partSize: PART_SIZE });
  } catch (error) {
    await sql`UPDATE meeting_jobs SET status = 'failed', error_code = 'upload_failed', updated_at = now()
              WHERE id = ${meetingID}::uuid AND user_id = ${user.id}::uuid`;
    throw error;
  }
});
