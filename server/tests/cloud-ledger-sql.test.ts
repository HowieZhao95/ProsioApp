import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

// Executes real PostgreSQL SQL/PLpgSQL in an isolated WASM database, not mocks.
// PGlite has one connection: real multi-worker/Neon concurrency is a separate release gate.
let db: PGlite;
const period = "2026-10-01T00:00:00Z";
const end = "2026-11-01T00:00:00Z";
let user: string;
async function reserve(id: string, seconds: number, limit = 3, fingerprint = "a", userId = user) {
  return db.query<{ was_created: boolean; operation_state: string; cached_response: unknown }>(
    "SELECT * FROM reserve_cloud_operation($1,$2,$3,$4,$5,$6,$7)", [userId,id,fingerprint,period,end,seconds,limit]);
}
async function finish(id: string, succeeded = true, userId = user) {
  return db.query("SELECT finish_cloud_operation($1,$2,$3,$4)", [userId,id,JSON.stringify({ status: succeeded ? 200 : 502, body: { text: "hello" } }),succeeded]);
}
async function meeting(seconds: number, limit = 3) {
  return db.query("SELECT * FROM reserve_meeting_job($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    [randomUUID(),user,period,end,seconds,limit,200,"fixture/object",[]]);
}
beforeAll(async () => {
  db = await PGlite.create();
  await db.exec(`CREATE TABLE users(id uuid PRIMARY KEY, email text NOT NULL UNIQUE);
    CREATE TABLE usage_events(id uuid DEFAULT gen_random_uuid() PRIMARY KEY, user_id uuid REFERENCES users(id),
      session_id uuid NOT NULL UNIQUE, engine_id text NOT NULL, audio_seconds double precision NOT NULL,
      started_at timestamptz NOT NULL, created_at timestamptz DEFAULT now());`);
  for (const file of ["meeting_jobs.sql","cloud_operations.sql"]) await db.exec(await readFile(new URL(`../sql/${file}`,import.meta.url),"utf8"));
}, 30000);
afterAll(async () => { await db?.close(); });
beforeEach(async () => {
  await db.exec("TRUNCATE users CASCADE;");
  user = randomUUID();
  await db.query("INSERT INTO users VALUES($1,$2)", [user,`${user}@example.test`]);
});

describe("SQL cloud ledger", () => {
  it("applies the migration twice without losing data", async () => {
    const id = randomUUID(); await reserve(id,2); await finish(id);
    await db.exec(await readFile(new URL("../sql/cloud_operations.sql",import.meta.url),"utf8"));
    expect((await reserve(id,2)).rows[0]?.was_created).toBe(false);
  });
  it("includes the requested duration and pending reservations in quota checks", async () => {
    await reserve(randomUUID(),2);
    await expect(reserve(randomUUID(),2)).rejects.toMatchObject({ code: "P0001" });
    expect((await reserve(randomUUID(),1)).rows[0]?.was_created).toBe(true);
  });
  it("stores result and usage once, replays, and rejects payload changes", async () => {
    const id = randomUUID(); await reserve(id,2);
    expect((await reserve(id,2)).rows[0]?.operation_state).toBe("pending");
    await finish(id); await finish(id);
    const replay = (await reserve(id,2)).rows[0]!;
    expect(replay.was_created).toBe(false);
    expect(replay.cached_response).toEqual({status:200,body:{text:"hello"}});
    expect((await db.query<{ n: number }>("SELECT count(*)::int n FROM usage_events")).rows[0]?.n).toBe(1);
    await expect(reserve(id,2,3,"different")).rejects.toMatchObject({ code: "P0003" });
  });
  it("releases failed quota while keeping the failure replay terminal", async () => {
    const id = randomUUID(); await reserve(id,2); await finish(id,false);
    expect((await reserve(id,2)).rows[0]?.operation_state).toBe("failed");
    expect((await reserve(randomUUID(),3)).rows[0]?.was_created).toBe(true);
    expect((await db.query<{ n: number }>("SELECT count(*)::int n FROM usage_events")).rows[0]?.n).toBe(0);
  });
  it("shares the quota boundary with meetings in both directions", async () => {
    await reserve(randomUUID(),2);
    await expect(meeting(2)).rejects.toMatchObject({ code: "P0001" });
    await db.exec("TRUNCATE cloud_operations;");
    await meeting(2);
    await expect(reserve(randomUUID(),2)).rejects.toMatchObject({ code: "P0001" });
  });
  it("allows the same session ID for two users", async () => {
    const other = randomUUID(); const id = randomUUID();
    await db.query("INSERT INTO users VALUES($1,$2)",[other,"other@example.test"]);
    await reserve(id,2); await reserve(id,2,3,"a",other);
    await finish(id); await finish(id,true,other);
    expect((await db.query<{ n: number }>("SELECT count(*)::int n FROM usage_events")).rows[0]?.n).toBe(2);
  });
  it("rejects non-finite durations at the database boundary", async () => {
    for (const seconds of [NaN,Infinity,-1]) await expect(reserve(randomUUID(),seconds)).rejects.toMatchObject({ code: "22023" });
  });
  it("limits text requests independently and rolls back rejected increments", async () => {
    for (let i=0;i<3;i++) await db.query("SELECT consume_model_request($1,$2,$3)",[user,period,3]);
    await expect(db.query("SELECT consume_model_request($1,$2,$3)",[user,period,3])).rejects.toMatchObject({code:"P0001"});
    expect((await db.query<{ requests:number }>("SELECT requests FROM model_request_usage")).rows[0]?.requests).toBe(3);
    await db.query("SELECT consume_model_request($1,$2,$3)",[user,end,3]);
  });
});
