import { describe, expect, it } from "vitest";
import { POST } from "@/app/api/meetings/jobs/route";
import { authedUser, jsonRequest } from "./helpers";

const body = { meetingID: crypto.randomUUID(), durationSeconds: 60,
  bytes: 1000000, languageHints: ["zh-CN"] };

describe("/api/meetings/jobs", () => {
  it("requires authentication before reserving a meeting", async () => {
    const response = await POST(jsonRequest("/api/meetings/jobs", "POST", body));
    expect(response.status).toBe(401);
  });

  it("fails closed when cloud infrastructure is not configured", async () => {
    const user = await authedUser();
    const response = await POST(jsonRequest("/api/meetings/jobs", "POST", body, user.authHeader));
    expect(response.status).toBe(503);
    expect((await response.json()).error.code).toBe("unavailable");
  });
});
