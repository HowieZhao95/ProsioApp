import { neon } from "@neondatabase/serverless";
import { ApiError } from "@/lib/errors";

export interface MeetingJob {
  id: string;
  user_id: string;
  status: "reserving" | "uploading" | "submitting" | "submitted" | "completed" | "failed" | "cancelled";
  expected_bytes: string;
  reserved_seconds: number;
  object_key: string;
  language_hints: string[];
  upload_id: string | null;
  soniox_id: string | null;
  transcript: unknown;
  error_code: string | null;
  expires_at: string;
}

export function meetingSQL() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new ApiError("unavailable", "Meeting cloud database is not configured");
  return neon(url);
}

export async function findMeetingJob(id: string, userId: string): Promise<MeetingJob> {
  const sql = meetingSQL();
  const rows = await sql`SELECT * FROM meeting_jobs WHERE id = ${id}::uuid AND user_id = ${userId}::uuid`;
  if (!rows[0]) throw new ApiError("not_found", "Meeting job not found");
  return rows[0] as unknown as MeetingJob;
}

export async function releaseMeetingJob(id: string, userId: string, status: "failed" | "cancelled", code: string) {
  const sql = meetingSQL();
  await sql`UPDATE meeting_jobs SET status = ${status}, error_code = ${code}, updated_at = now()
            WHERE id = ${id}::uuid AND user_id = ${userId}::uuid
              AND status IN ('reserving','uploading','submitting','submitted')`;
}
