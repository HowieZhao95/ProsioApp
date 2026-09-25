#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * Latency benchmark for POST /api/transcribe, run against a PRODUCTION
 * server (`npm run build && npx next start -p 3200`), never `next dev`
 * (dev-mode compilation/instrumentation overhead would swamp the numbers
 * we actually care about).
 *
 * For each clip, runs N requests (default 10), reports the first ("cold")
 * run separately from the rest, and computes p50/p90/min/max client-observed
 * latency over the warm runs, plus the mean of each stage from the
 * `Server-Timing` header the route now sends (see app/api/transcribe/route.ts
 * + lib/timing.ts).
 *
 * Usage (from server/):
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts --base-url http://localhost:3200 --n 10
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts --direct        # bypass our backend entirely: call the Gateway in-process, for comparison
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts --clips short16,en16
 *
 * Idle-gap mode: real dictation is almost always "first request after N
 * seconds of nobody talking", not a tight back-to-back loop — this mode
 * measures exactly that, on an already-warm, long-running server (NOT
 * cold-process restarts, which have their own, much larger and unrelated
 * variance — module load, first DNS lookup, TCP slow start):
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts --idle 15 --n 3
 *   npx tsx --env-file=../.env.local scripts/latency-bench.ts --idle 45 --n 3 --prewarm   # HEAD 1.5s before each POST
 * Each of the `--n` trials waits `--idle` seconds (since the previous
 * request finished) before firing; with `--prewarm`, a `HEAD
 * /api/transcribe` is sent 1.5s before the POST instead of the POST going
 * out cold. Compare a plain `--idle` run against the same `--idle
 * --prewarm` run to see whether pre-warming helps at that idle length.
 *
 * Requires AI_GATEWAY_API_KEY (for --direct, and transitively for the
 * server under test) and, for the backend mode, the server to be running
 * with PROSIO_DEV_AUTH=1 so this script can mint a session token.
 */

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";

import { transcribeBatch } from "../lib/gateway";

const DEFAULT_CLIPS_DIR = "/private/tmp/claude-501/-Users-guest01-projectCodeMac2-ProsioApp/live";
const DEFAULT_CLIPS = ["short16", "mixed16", "list16", "en16"];

interface Args {
  baseUrl: string;
  n: number;
  direct: boolean;
  clips: string[];
  clipsDir: string;
  /** Seconds to wait before each trial, measuring the "first request after idle" case. Undefined = normal cold+warm mode. */
  idleSeconds?: number;
  /** Idle mode only: send a HEAD 1.5s before the POST instead of firing the POST cold. */
  prewarm: boolean;
}

const PREWARM_LEAD_SECONDS = 1.5;

function parseArgs(argv: string[]): Args {
  const args: Args = {
    baseUrl: "http://localhost:3200",
    n: 10,
    direct: false,
    clips: DEFAULT_CLIPS,
    clipsDir: DEFAULT_CLIPS_DIR,
    prewarm: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--base-url") args.baseUrl = argv[++i]!;
    else if (a === "--n") args.n = Number(argv[++i]);
    else if (a === "--direct") args.direct = true;
    else if (a === "--clips") args.clips = argv[++i]!.split(",");
    else if (a === "--clips-dir") args.clipsDir = argv[++i]!;
    else if (a === "--idle") args.idleSeconds = Number(argv[++i]);
    else if (a === "--prewarm") args.prewarm = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (args.prewarm && args.idleSeconds === undefined) {
    throw new Error("--prewarm only makes sense with --idle <seconds>");
  }
  if (args.prewarm && args.direct) {
    throw new Error("--prewarm sends a HEAD to the backend; not meaningful with --direct");
  }
  return args;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// --- stats -------------------------------------------------------------

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx]!;
}

function stats(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    n: sorted.length,
    min: sorted[0] ?? NaN,
    max: sorted[sorted.length - 1] ?? NaN,
    p50: percentile(sorted, 50),
    p90: percentile(sorted, 90),
    mean: sorted.length ? sorted.reduce((a, b) => a + b, 0) / sorted.length : NaN,
  };
}

function fmt(n: number): string {
  return Number.isFinite(n) ? n.toFixed(0) : "-";
}

// --- Server-Timing parsing -----------------------------------------------

/** Parses `"auth;dur=1.2, parse;dur=0.4, total;dur=812.3"` into `{ auth: 1.2, parse: 0.4, total: 812.3 }`. */
function parseServerTiming(header: string | null): Record<string, number> {
  if (!header) return {};
  const out: Record<string, number> = {};
  for (const part of header.split(",")) {
    const m = /^\s*([\w-]+)\s*;\s*dur=([\d.]+)/.exec(part);
    if (m) out[m[1]!] = Number(m[2]);
  }
  return out;
}

function meanBreakdown(rows: Record<string, number>[]): Record<string, number> {
  const keys = new Set<string>();
  for (const r of rows) for (const k of Object.keys(r)) keys.add(k);
  const out: Record<string, number> = {};
  for (const k of keys) {
    const vals = rows.map((r) => r[k]).filter((v): v is number => v !== undefined);
    out[k] = vals.reduce((a, b) => a + b, 0) / vals.length;
  }
  return out;
}

// --- backend (through our API) run ----------------------------------------

async function mintToken(baseUrl: string): Promise<string> {
  const res = await fetch(`${baseUrl}/api/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `latency-bench-${randomUUID()}@example.com` }),
  });
  if (!res.ok) {
    throw new Error(
      `Could not mint a dev session token from ${baseUrl} (status ${res.status}). ` +
        `Is the server running with PROSIO_DEV_AUTH=1?`
    );
  }
  const body = (await res.json()) as { sessionToken: string };
  return body.sessionToken;
}

interface RunResult {
  ok: boolean;
  status: number;
  clientLatencyMs: number;
  serverTiming: Record<string, number>;
  durationSeconds?: number;
  error?: string;
}

async function runBackendOnce(baseUrl: string, token: string, audioBase64: string): Promise<RunResult> {
  const t0 = performance.now();
  const res = await fetch(`${baseUrl}/api/transcribe`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ audio: audioBase64, mode: "smart", sessionID: randomUUID() }),
  });
  const clientLatencyMs = performance.now() - t0;
  const serverTiming = parseServerTiming(res.headers.get("server-timing"));
  if (!res.ok) {
    const body = await res.json().catch(() => null);
    return { ok: false, status: res.status, clientLatencyMs, serverTiming, error: JSON.stringify(body) };
  }
  const body = (await res.json()) as { durationSeconds: number };
  return { ok: true, status: res.status, clientLatencyMs, serverTiming, durationSeconds: body.durationSeconds };
}

// --- direct (in-process Gateway, bypassing our backend) run ---------------

async function runDirectOnce(audioBuffer: Buffer): Promise<RunResult> {
  const t0 = performance.now();
  try {
    await transcribeBatch({ audio: audioBuffer, mode: "smart", vocabulary: [], languageHints: [] });
    return { ok: true, status: 200, clientLatencyMs: performance.now() - t0, serverTiming: {} };
  } catch (err) {
    return {
      ok: false,
      status: 0,
      clientLatencyMs: performance.now() - t0,
      serverTiming: {},
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

// --- idle-gap mode: each trial is its own "first request after N idle seconds" ---

async function runIdleTrial(args: Args, baseUrl: string, token: string, audioBase64: string): Promise<RunResult> {
  const idleMs = (args.idleSeconds ?? 0) * 1000;
  if (args.prewarm) {
    const leadMs = PREWARM_LEAD_SECONDS * 1000;
    await sleep(Math.max(0, idleMs - leadMs));
    await fetch(`${baseUrl}/api/transcribe`, { method: "HEAD" }).catch(() => undefined);
    await sleep(leadMs);
  } else {
    await sleep(idleMs);
  }
  return runBackendOnce(baseUrl, token, audioBase64);
}

function printIdleReport(clipName: string, args: Args, trials: RunResult[]) {
  const s = stats(trials.map((r) => r.clientLatencyMs));
  const gatewayDurs = trials.map((r) => r.serverTiming.gateway).filter((v): v is number => v !== undefined);
  const failures = trials.filter((r) => !r.ok).length;
  console.log(`\n${clipName}  (idle=${args.idleSeconds}s${args.prewarm ? `, prewarm (HEAD ${PREWARM_LEAD_SECONDS}s before)` : ""})`);
  console.log(`  trials: ${trials.map((r) => fmt(r.clientLatencyMs)).join(", ")}ms${failures ? `  (${failures} failed)` : ""}`);
  console.log(`  client latency: p50=${fmt(s.p50)}ms min=${fmt(s.min)}ms max=${fmt(s.max)}ms mean=${fmt(s.mean)}ms`);
  if (gatewayDurs.length > 0) {
    const gs = stats(gatewayDurs);
    console.log(`  gateway stage:  p50=${fmt(gs.p50)}ms min=${fmt(gs.min)}ms max=${fmt(gs.max)}ms mean=${fmt(gs.mean)}ms`);
  }
}

// --- reporting --------------------------------------------------------------

function printClipReport(clipName: string, cold: RunResult, warm: RunResult[]) {
  const s = stats(warm.map((r) => r.clientLatencyMs));
  console.log(`\n${clipName}`);
  console.log(
    `  cold: ${cold.ok ? fmt(cold.clientLatencyMs) + "ms" : `FAILED (${cold.status}) ${cold.error ?? ""}`}` +
      (Object.keys(cold.serverTiming).length ? `  [${formatBreakdown(cold.serverTiming)}]` : "")
  );
  const failures = warm.filter((r) => !r.ok).length;
  console.log(
    `  warm (n=${s.n}${failures ? `, ${failures} failed` : ""}): p50=${fmt(s.p50)}ms p90=${fmt(s.p90)}ms min=${fmt(s.min)}ms max=${fmt(s.max)}ms mean=${fmt(s.mean)}ms`
  );
  const okWarm = warm.filter((r) => r.ok && Object.keys(r.serverTiming).length > 0);
  if (okWarm.length > 0) {
    const breakdown = meanBreakdown(okWarm.map((r) => r.serverTiming));
    console.log(`  mean server breakdown: ${formatBreakdown(breakdown)}`);
  }
}

function formatBreakdown(b: Record<string, number>): string {
  return Object.entries(b)
    .map(([k, v]) => `${k}=${v.toFixed(1)}ms`)
    .join(" ");
}

// --- main --------------------------------------------------------------

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (!process.env.AI_GATEWAY_API_KEY) {
    console.error("AI_GATEWAY_API_KEY is not set. Run with --env-file=../.env.local (see the shebang) or export it.");
    process.exit(1);
  }

  const idleMode = args.idleSeconds !== undefined;
  console.log(args.direct ? "Mode: --direct (in-process Gateway call, bypassing our backend)" : `Mode: backend (${args.baseUrl})`);
  if (idleMode) {
    console.log(
      `Clips: ${args.clips.join(", ")}  (${args.n} trial(s) each, ${args.idleSeconds}s idle before every trial${
        args.prewarm ? `, HEAD ${PREWARM_LEAD_SECONDS}s before each POST` : ""
      })\n`
    );
  } else {
    console.log(`Clips: ${args.clips.join(", ")}  (n=${args.n} warm runs each, plus 1 cold run)\n`);
  }

  let token = "";
  if (!args.direct) {
    token = await mintToken(args.baseUrl);
  }

  for (const clip of args.clips) {
    const path = `${args.clipsDir}/${clip}.wav`;
    let audioBuffer: Buffer;
    try {
      audioBuffer = await readFile(path);
    } catch {
      console.log(`\n${clip}: SKIPPED (file not found: ${path})`);
      continue;
    }
    const audioBase64 = audioBuffer.toString("base64");
    const clipName = basename(path, ".wav");

    if (idleMode) {
      const trials: RunResult[] = [];
      for (let i = 0; i < args.n; i++) {
        trials.push(await runIdleTrial(args, args.baseUrl, token, audioBase64));
      }
      printIdleReport(clipName, args, trials);
      continue;
    }

    const runOnce = () => (args.direct ? runDirectOnce(audioBuffer) : runBackendOnce(args.baseUrl, token, audioBase64));

    const cold = await runOnce();
    const warm: RunResult[] = [];
    for (let i = 0; i < args.n; i++) {
      warm.push(await runOnce());
    }

    printClipReport(clipName, cold, warm);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
