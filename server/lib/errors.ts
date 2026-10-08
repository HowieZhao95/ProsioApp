// Error envelope shared by every route, per docs/API.md:
//   { "error": { "code": "<code>", "message": "<human text>" } }

export type ErrorCode =
  | "unauthorized"
  | "forbidden"
  | "quota_exceeded"
  | "bad_request"
  | "payload_too_large"
  | "unsupported_media_type"
  | "upstream_error"
  | "not_found"
  | "conflict"
  | "unavailable";

const STATUS_BY_CODE: Record<ErrorCode, number> = {
  unauthorized: 401,
  forbidden: 403,
  quota_exceeded: 402,
  bad_request: 400,
  payload_too_large: 413,
  unsupported_media_type: 415,
  upstream_error: 502,
  not_found: 404,
  conflict: 409,
  unavailable: 503,
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: number;

  constructor(code: ErrorCode, message: string) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = STATUS_BY_CODE[code];
  }
}

export function errorBody(code: ErrorCode, message: string) {
  return { error: { code, message } };
}

export function errorResponse(err: ApiError): Response {
  const message = isProduction() && (err.code === "upstream_error" || err.code === "unavailable")
    ? "Service temporarily unavailable. Please try again." : err.message;
  return Response.json(errorBody(err.code, message), { status: err.status });
}

/**
 * Converts any thrown value into a Response following the API error envelope.
 * Unexpected (non-ApiError) failures are logged and surfaced as a generic
 * 502 upstream_error, since docs/API.md defines no catch-all 500 code and a
 * bug surfacing as "try again" is more useful to the client than a raw 500.
 */
export function toErrorResponse(err: unknown): Response {
  if (err instanceof ApiError) {
    return errorResponse(err);
  }
  console.error("[unhandled]", isProduction() ? "Server request failed" : err);
  const message = !isProduction() && err instanceof Error ? err.message : "Unexpected server error";
  return Response.json(errorBody("upstream_error", message), { status: 502 });
}

/** Wraps a route handler so any thrown ApiError (or unexpected error) becomes a proper Response. */
export function withErrorHandling<Args extends unknown[]>(
  handler: (...args: Args) => Promise<Response>
): (...args: Args) => Promise<Response> {
  return async (...args: Args) => {
    try {
      return await handler(...args);
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

function isProduction(): boolean {
  return process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production";
}
