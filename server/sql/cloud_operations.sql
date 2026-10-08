-- Apply users/usage_events, then meeting_jobs.sql, then this migration.
-- Both reservation functions use the same user/month lock. Never apply partially.
BEGIN;
ALTER TABLE usage_events DROP CONSTRAINT IF EXISTS usage_events_session_id_key;
DROP INDEX IF EXISTS usage_events_session_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS usage_events_user_session_key ON usage_events(user_id, session_id);
CREATE TABLE IF NOT EXISTS cloud_operations (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  fingerprint text NOT NULL,
  period_start timestamptz NOT NULL,
  seconds double precision NOT NULL CHECK (seconds >= 0 AND seconds < 'Infinity'::float8),
  state text NOT NULL CHECK (state IN ('pending','completed','failed')),
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id, session_id)
);
CREATE INDEX IF NOT EXISTS cloud_operations_pending ON cloud_operations(user_id, period_start) WHERE state = 'pending';
CREATE TABLE IF NOT EXISTS model_request_usage (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start timestamptz NOT NULL,
  requests integer NOT NULL CHECK (requests >= 0),
  PRIMARY KEY(user_id, period_start)
);
CREATE OR REPLACE FUNCTION reserve_cloud_operation(
  p_user uuid, p_session uuid, p_fingerprint text, p_period timestamptz,
  p_end timestamptz, p_seconds double precision, p_limit double precision
) RETURNS TABLE(was_created boolean, operation_state text, cached_response jsonb)
LANGUAGE plpgsql AS $$
DECLARE existing cloud_operations%ROWTYPE; used_seconds double precision;
BEGIN
  IF NOT (p_seconds >= 0 AND p_seconds < 'Infinity'::float8 AND p_limit > 0 AND p_limit < 'Infinity'::float8 AND p_end > p_period) THEN
    RAISE EXCEPTION 'invalid reservation' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_user::text), hashtext(to_char(p_period AT TIME ZONE 'UTC', 'YYYY-MM')));
  SELECT * INTO existing FROM cloud_operations WHERE user_id = p_user AND session_id = p_session;
  IF FOUND THEN
    IF existing.fingerprint <> p_fingerprint THEN RAISE EXCEPTION 'request conflict' USING ERRCODE = 'P0003'; END IF;
    RETURN QUERY SELECT false, existing.state, existing.response;
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM usage_events WHERE user_id = p_user AND session_id = p_session) THEN
    RAISE EXCEPTION 'request conflict' USING ERRCODE = 'P0003';
  END IF;
  SELECT COALESCE((SELECT sum(audio_seconds) FROM usage_events WHERE user_id = p_user AND started_at >= p_period AND started_at < p_end), 0)
       + COALESCE((SELECT sum(seconds) FROM cloud_operations WHERE user_id = p_user AND period_start = p_period AND state = 'pending'), 0)
       + COALESCE((SELECT sum(reserved_seconds) FROM meeting_jobs WHERE user_id = p_user AND period_start = p_period
                     AND status IN ('reserving','uploading','submitting','submitted','completed')
                     AND (status = 'completed' OR expires_at > now())), 0)
    INTO used_seconds;
  IF used_seconds >= p_limit OR used_seconds + p_seconds > p_limit THEN RAISE EXCEPTION 'quota_exceeded' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO cloud_operations(user_id,session_id,fingerprint,period_start,seconds,state)
    VALUES(p_user,p_session,p_fingerprint,p_period,p_seconds,'pending');
  RETURN QUERY SELECT true, 'pending'::text, NULL::jsonb;
END;
$$;
CREATE OR REPLACE FUNCTION finish_cloud_operation(p_user uuid, p_session uuid, p_response jsonb, p_succeeded boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE operation cloud_operations%ROWTYPE;
BEGIN
  SELECT * INTO operation FROM cloud_operations WHERE user_id = p_user AND session_id = p_session;
  IF NOT FOUND THEN RAISE EXCEPTION 'operation missing' USING ERRCODE = 'P0002'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_user::text), hashtext(to_char(operation.period_start AT TIME ZONE 'UTC', 'YYYY-MM')));
  SELECT * INTO operation FROM cloud_operations WHERE user_id = p_user AND session_id = p_session FOR UPDATE;
  IF operation.state <> 'pending' THEN RETURN; END IF;
  IF p_succeeded THEN
    INSERT INTO usage_events(user_id,session_id,engine_id,audio_seconds,started_at)
      VALUES(p_user,p_session,'cloud.gemini-3.5-transcribe',operation.seconds,operation.period_start)
      ON CONFLICT(user_id,session_id) DO NOTHING;
  END IF;
  UPDATE cloud_operations SET state = CASE WHEN p_succeeded THEN 'completed' ELSE 'failed' END,
    response = p_response, updated_at = now() WHERE user_id = p_user AND session_id = p_session;
END;
$$;
CREATE OR REPLACE FUNCTION consume_model_request(p_user uuid, p_period timestamptz, p_limit integer)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE used integer;
BEGIN
  IF p_limit <= 0 THEN RAISE EXCEPTION 'invalid text limit' USING ERRCODE = '22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_user::text), hashtext(to_char(p_period AT TIME ZONE 'UTC', 'YYYY-MM')));
  SELECT requests INTO used FROM model_request_usage WHERE user_id = p_user AND period_start = p_period;
  IF COALESCE(used, 0) >= p_limit THEN RAISE EXCEPTION 'quota_exceeded' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO model_request_usage(user_id,period_start,requests) VALUES(p_user,p_period,1)
    ON CONFLICT(user_id,period_start) DO UPDATE SET requests = model_request_usage.requests + 1;
END;
$$;
COMMIT;
-- Pending operations deliberately do not expire automatically: a worker crash
-- may have incurred model cost. Reconcile their outcome before releasing them.
-- Cached responses contain transcript text: set a retention/deletion policy
-- before production; do not delete this month's identity records on retry.
