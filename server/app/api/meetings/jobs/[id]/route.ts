import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { findMeetingJob, meetingSQL, releaseMeetingJob } from "@/lib/meetings/db";
import { removeUpload } from "@/lib/meetings/storage";
import { getTranscription, getTranscript, removeTranscription } from "@/lib/meetings/soniox";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

async function identify(req: Request, context: { params: Promise<{ id: string }> }) {
  const user = await requireUser(req);
  const { id } = await context.params;
  if (!z.string().uuid().safeParse(id).success) throw new ApiError("bad_request", "Invalid job ID");
  return { id, user, job: await findMeetingJob(id, user.id) };
}

export const GET = withErrorHandling(async (req: Request, context: { params: Promise<{ id: string }> }) => {
  const { id, user, job } = await identify(req, context);
  if (job.status === "completed") return Response.json({ status: "completed", transcript: job.transcript });
  if (job.status === "failed" || job.status === "cancelled") {
    return Response.json({ status: job.status, errorCode: job.error_code });
  }
  if (job.status !== "submitted" || !job.soniox_id) return Response.json({ status: job.status });
  const provider = await getTranscription(job.soniox_id);
  if (provider.status === "error" || provider.status === "failed") {
    await releaseMeetingJob(id, user.id, "failed", "provider_failed");
    await removeUpload(job.object_key, job.upload_id);
    await removeTranscription(job.soniox_id);
    return Response.json({ status: "failed", errorCode: "provider_failed" });
  }
  if (provider.status !== "completed") return Response.json({ status: "submitted" });
  const transcript = await getTranscript(job.soniox_id);
  const sql = meetingSQL();
  const actualSeconds = typeof provider.audio_duration_ms === "number"
    ? Math.min(18_000, Math.max(1, provider.audio_duration_ms / 1000))
    : job.reserved_seconds;
  await sql`UPDATE meeting_jobs SET status = 'completed', transcript = ${JSON.stringify(transcript)}::jsonb,
            reserved_seconds = ${actualSeconds}, updated_at = now()
            WHERE id = ${id}::uuid AND user_id = ${user.id}::uuid AND status = 'submitted'`;
  await removeUpload(job.object_key, job.upload_id);
  await removeTranscription(job.soniox_id);
  return Response.json({ status: "completed", transcript });
});

export const DELETE = withErrorHandling(async (req: Request, context: { params: Promise<{ id: string }> }) => {
  const { id, user, job } = await identify(req, context);
  if (job.status === "completed") throw new ApiError("conflict", "Completed meeting cannot be cancelled");
  if (job.status !== "failed" && job.status !== "cancelled") {
    await releaseMeetingJob(id, user.id, "cancelled", "cancelled");
    await removeUpload(job.object_key, job.upload_id);
    if (job.soniox_id) await removeTranscription(job.soniox_id);
  }
  return new Response(null, { status: 204 });
});
