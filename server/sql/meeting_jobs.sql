-- Apply after the existing users and usage_events tables. The function is the
-- quota boundary: a per-user/month advisory transaction lock serializes two
-- simultaneous reservations before either sees the other's balance.
CREATE TABLE IF NOT EXISTS meeting_jobs (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start timestamptz NOT NULL,
  reserved_seconds double precision NOT NULL CHECK (reserved_seconds > 0 AND reserved_seconds <= 18000),
  expected_bytes bigint NOT NULL CHECK (expected_bytes > 0),
  object_key text NOT NULL,
  language_hints text[] NOT NULL DEFAULT '{}',
  upload_id text,
  status text NOT NULL CHECK (status IN ('reserving','uploading','submitting','submitted','completed','failed','cancelled')),
  soniox_id text,
  transcript jsonb,
  error_code text,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meeting_jobs_user_period ON meeting_jobs(user_id, period_start);

CREATE OR REPLACE FUNCTION reserve_meeting_job(
  p_id uuid, p_user uuid, p_period timestamptz, p_period_end timestamptz,
  p_seconds double precision, p_limit double precision, p_bytes bigint,
  p_object_key text, p_language_hints text[]
) RETURNS TABLE(was_created boolean, job_status text)
LANGUAGE plpgsql AS $$
DECLARE
  existing meeting_jobs%ROWTYPE;
  had_existing boolean;
  used_seconds double precision;
BEGIN
  IF p_seconds <= 0 OR p_seconds > 18000 OR p_bytes <= 0 THEN
    RAISE EXCEPTION 'invalid meeting reservation' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_user::text), hashtext(to_char(p_period AT TIME ZONE 'UTC', 'YYYY-MM')));
  SELECT * INTO existing FROM meeting_jobs WHERE id = p_id;
  had_existing := FOUND;
  IF had_existing THEN
    IF existing.user_id <> p_user THEN RAISE EXCEPTION 'not found' USING ERRCODE = 'P0002'; END IF;
    IF existing.status NOT IN ('failed', 'cancelled') THEN
      RETURN QUERY SELECT false, existing.status;
      RETURN;
    END IF;
  END IF;
  SELECT COALESCE((SELECT sum(audio_seconds) FROM usage_events
                   WHERE user_id = p_user AND started_at >= p_period AND started_at < p_period_end), 0)
       + COALESCE((SELECT sum(reserved_seconds) FROM meeting_jobs
                   WHERE user_id = p_user AND period_start = p_period
                     AND status IN ('reserving','uploading','submitting','submitted','completed')
                     AND (status = 'completed' OR expires_at > now())), 0)
       + COALESCE((SELECT sum(seconds) FROM cloud_operations
                   WHERE user_id = p_user AND period_start = p_period AND state = 'pending'), 0)
    INTO used_seconds;
  IF used_seconds + p_seconds > p_limit THEN
    RAISE EXCEPTION 'quota_exceeded' USING ERRCODE = 'P0001';
  END IF;
  IF had_existing THEN
    UPDATE meeting_jobs SET period_start = p_period, reserved_seconds = p_seconds,
      expected_bytes = p_bytes, object_key = p_object_key,
      language_hints = p_language_hints, status = 'reserving',
      upload_id = NULL, soniox_id = NULL, transcript = NULL, error_code = NULL,
      expires_at = now() + interval '24 hours', updated_at = now()
    WHERE id = p_id;
  ELSE
    INSERT INTO meeting_jobs(id,user_id,period_start,reserved_seconds,expected_bytes,object_key,language_hints,status,expires_at)
    VALUES(p_id,p_user,p_period,p_seconds,p_bytes,p_object_key,p_language_hints,'reserving',now() + interval '24 hours');
  END IF;
  RETURN QUERY SELECT true, 'reserving'::text;
END;
$$;
