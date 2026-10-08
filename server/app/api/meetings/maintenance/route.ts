import { meetingSQL } from "@/lib/meetings/db";
import { removeUpload } from "@/lib/meetings/storage";
import { removeTranscription } from "@/lib/meetings/soniox";

export const dynamic = "force-dynamic";

/** Vercel Cron uses CRON_SECRET as Bearer auth. Expired reservations release quota. */
export async function GET(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.get("authorization") !== `Bearer ${secret}`) {
    return new Response(null, { status: 401 });
  }
  const sql = meetingSQL();
  const jobs = await sql`SELECT id, user_id, object_key, upload_id, soniox_id
                         FROM meeting_jobs WHERE status IN ('reserving','uploading','submitting','submitted')
                           AND expires_at < now() ORDER BY expires_at LIMIT 50`;
  let cleaned = 0;
  for (const job of jobs) {
    const claimed = await sql`UPDATE meeting_jobs SET status = 'failed', error_code = 'expired', updated_at = now()
                              WHERE id = ${job.id}::uuid AND status IN ('reserving','uploading','submitting','submitted')
                                AND expires_at < now() RETURNING id`;
    if (!claimed[0]) continue;
    await removeUpload(String(job.object_key), job.upload_id ? String(job.upload_id) : null);
    if (job.soniox_id) await removeTranscription(String(job.soniox_id));
    cleaned += 1;
  }
  return Response.json({ cleaned });
}
