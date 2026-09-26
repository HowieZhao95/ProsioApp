// Cheap request-timing helper: accumulates named stage durations and
// renders them as a standard `Server-Timing` response header
// (https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Server-Timing),
// browser devtools / curl -w friendly. Overhead is a handful of
// `performance.now()` calls — negligible, fine to leave on in prod.

export class RequestTimer {
  private readonly startedAt: number;
  private lastMarkAt: number;
  private readonly stages: { name: string; durMs: number }[] = [];

  constructor() {
    this.startedAt = performance.now();
    this.lastMarkAt = this.startedAt;
  }

  /** Records the duration since the previous mark (or construction) under `name`. */
  mark(name: string): void {
    const now = performance.now();
    this.stages.push({ name, durMs: now - this.lastMarkAt });
    this.lastMarkAt = now;
  }

  totalMs(): number {
    return performance.now() - this.startedAt;
  }

  /**
   * `Server-Timing` header value: `auth;dur=1.2, parse;dur=0.4, ..., total;dur=812.3`.
   * Pass `{ includeTotal: false }` when headers must go out before the
   * request is actually done (e.g. a streaming response, where later
   * stages like `ttft` aren't known yet) — a `total` computed at that point
   * would just be elapsed-so-far mislabeled as the real total.
   */
  toServerTimingHeader({ includeTotal = true }: { includeTotal?: boolean } = {}): string {
    const entries = includeTotal
      ? [...this.stages.map((s) => ({ name: s.name, durMs: s.durMs })), { name: "total", durMs: this.totalMs() }]
      : this.stages.map((s) => ({ name: s.name, durMs: s.durMs }));
    return entries.map((s) => `${s.name};dur=${s.durMs.toFixed(1)}`).join(", ");
  }

  /** Plain object for structured logging, e.g. `{ auth: 1.2, parse: 0.4, total: 812.3 }`. */
  toObject(): Record<string, number> {
    const obj: Record<string, number> = {};
    for (const s of this.stages) obj[s.name] = Math.round(s.durMs * 10) / 10;
    obj.total = Math.round(this.totalMs() * 10) / 10;
    return obj;
  }
}
