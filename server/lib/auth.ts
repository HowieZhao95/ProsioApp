import { SignJWT, jwtVerify, errors as joseErrors } from "jose";
import { ApiError } from "./errors";

const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 days, per docs/API.md

export interface SessionUser {
  id: string;
  email: string;
}

function jwtSecret(): Uint8Array {
  const secret = process.env.PROSIO_JWT_SECRET;
  if (!secret) {
    // Not a client-facing error: this is a server misconfiguration.
    throw new Error("PROSIO_JWT_SECRET is not set");
  }
  const bytes = new TextEncoder().encode(secret);
  if ((process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production") && bytes.length < 32) {
    throw new ApiError("unavailable", "Session signing configuration is invalid");
  }
  return bytes;
}

/** Signs a session token. Claims: sub (user id), email, exp (30 days). */
export async function signSessionToken(user: SessionUser): Promise<string> {
  return new SignJWT({ email: user.email })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(user.id)
    .setIssuedAt()
    .setExpirationTime(Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS)
    .sign(jwtSecret());
}

/** Verifies a session token and returns its claims, or throws ApiError("unauthorized"). */
export async function verifySessionToken(token: string): Promise<SessionUser> {
  try {
    const { payload } = await jwtVerify(token, jwtSecret(), { algorithms: ["HS256"] });
    if (typeof payload.sub !== "string" || typeof payload.email !== "string") {
      throw new ApiError("unauthorized", "Malformed session token");
    }
    return { id: payload.sub, email: payload.email };
  } catch (err) {
    if (err instanceof ApiError) throw err;
    if (err instanceof joseErrors.JOSEError) {
      throw new ApiError("unauthorized", "Invalid or expired session token");
    }
    throw err;
  }
}

/** Extracts and verifies the bearer session token from a request. Throws ApiError("unauthorized") if missing/invalid. */
export async function requireUser(req: Request): Promise<SessionUser> {
  const header = req.headers.get("authorization") ?? req.headers.get("Authorization");
  if (!header) {
    throw new ApiError("unauthorized", "Missing Authorization header");
  }
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    throw new ApiError("unauthorized", "Authorization header must be a Bearer token");
  }
  return verifySessionToken(match[1]!.trim());
}
