import { beforeEach, describe, expect, it } from "vitest";
import { POST } from "@/app/api/auth/dev/route";
import { verifySessionToken } from "@/lib/auth";
import { resetStoreForTests } from "@/lib/store";
import { jsonRequest } from "./helpers";

describe("POST /api/auth/dev", () => {
  beforeEach(() => {
    resetStoreForTests();
    process.env.PROSIO_DEV_AUTH = "1";
  });

  it("404s when PROSIO_DEV_AUTH is not '1'", async () => {
    process.env.PROSIO_DEV_AUTH = "0";
    const res = await POST(jsonRequest("/api/auth/dev", "POST", { email: "a@b.com" }));
    expect(res.status).toBe(404);
  });

  it("400s on a bad body", async () => {
    const res = await POST(jsonRequest("/api/auth/dev", "POST", { email: "not-an-email" }));
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error.code).toBe("bad_request");
  });

  it("returns a sessionToken + user, and the token verifies", async () => {
    const res = await POST(jsonRequest("/api/auth/dev", "POST", { email: "a@b.com" }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.user.email).toBe("a@b.com");
    expect(typeof body.sessionToken).toBe("string");

    const claims = await verifySessionToken(body.sessionToken);
    expect(claims.id).toBe(body.user.id);
    expect(claims.email).toBe("a@b.com");
  });

  it("is stable per email (same user id on repeat sign-in)", async () => {
    const first = await (await POST(jsonRequest("/api/auth/dev", "POST", { email: "same@b.com" }))).json();
    const second = await (await POST(jsonRequest("/api/auth/dev", "POST", { email: "same@b.com" }))).json();
    expect(first.user.id).toBe(second.user.id);
  });
});
