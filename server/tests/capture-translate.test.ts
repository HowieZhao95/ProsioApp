import { beforeEach, describe, expect, it, vi } from "vitest";
const { streamTextMock } = vi.hoisted(() => ({ streamTextMock: vi.fn() }));
vi.mock("ai", () => ({ streamText: streamTextMock }));
vi.mock("@ai-sdk/gateway", () => ({ createGateway: () => (id: string) => ({ modelId: id }) }));
import { POST } from "@/app/api/capture/translate/route";
import { authedUser, jsonRequest } from "./helpers";
import { getStore } from "@/lib/store";

function output(text: string) {
  streamTextMock.mockReturnValue({ textStream: (async function* () { yield text.slice(0, 5); yield text.slice(5); })() });
}
async function request(body: unknown = { texts: ["Hello", "Save"], targetLanguage: "zh-Hans" }) {
  const user = await authedUser();
  return POST(jsonRequest("/api/capture/translate", "POST", body, user.authHeader));
}
describe("screenshot batch translation", () => {
  beforeEach(() => { streamTextMock.mockReset(); output('{"translations":["你好","保存"]}'); });
  it("requires authentication", async () => {
    const result = await POST(jsonRequest("/api/capture/translate", "POST", { texts: ["Hello"], targetLanguage: "zh-Hans" }));
    expect(result.status).toBe(401);
    expect(streamTextMock).not.toHaveBeenCalled();
  });
  it("preserves segment mapping in one model call and treats text as data", async () => {
    const response = await request();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ translations: ["你好", "保存"] });
    expect(streamTextMock).toHaveBeenCalledTimes(1);
    const args = streamTextMock.mock.calls[0]![0];
    expect(JSON.parse(args.messages[0].content)).toEqual(["Hello", "Save"]);
    expect(args.system).toContain("untrusted source text");
    expect(response.headers.get("Server-Timing")).toBeTruthy();
  });
  it.each([
    { texts: [], targetLanguage: "zh-Hans" },
    { texts: Array(41).fill("Hello"), targetLanguage: "zh-Hans" },
    { texts: ["x".repeat(3501)], targetLanguage: "zh-Hans" },
    { texts: ["x".repeat(2000), "y".repeat(2000)], targetLanguage: "zh-Hans" },
    { texts: ["Hello"], targetLanguage: "invented" },
    { texts: ["   "], targetLanguage: "en-US" },
  ])("rejects invalid or oversized batches %#", async (body) => {
    expect((await request(body)).status).toBe(400);
    expect(streamTextMock).not.toHaveBeenCalled();
  });
  it.each(['{"translations":["你好"]}', '{"translations":["你好",""]}', '{"translations":["你好","保存","多余"]}', "not json"]) (
    "fails instead of overlaying incomplete or malformed output %#", async (text) => {
      output(text);
      const response = await request();
      expect(response.status).toBe(502);
      expect((await response.json()).error.code).toBe("upstream_error");
    });
  it("accepts an incidental JSON fence", async () => {
    output('```json\n{"translations":["你好","保存"]}\n```');
    expect((await request()).status).toBe(200);
  });
  it("honors the existing monthly quota", async () => {
    const user = await authedUser();
    await getStore().recordUsage(user.id, { sessionID: crypto.randomUUID(), engineID: "test", audioSeconds: 999999, startedAt: new Date().toISOString() });
    const response = await POST(jsonRequest("/api/capture/translate", "POST", { texts: ["Hi"], targetLanguage: "zh-Hans" }, user.authHeader));
    expect(response.status).toBe(402);
    expect(streamTextMock).not.toHaveBeenCalled();
  });
});
