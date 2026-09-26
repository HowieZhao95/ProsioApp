import { beforeEach, describe, expect, it, vi } from "vitest";

const { generateTextMock } = vi.hoisted(() => ({ generateTextMock: vi.fn() }));

vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, generateText: generateTextMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => (id: string) => ({ modelId: id }),
}));

import { needsListRepair, hasMarkdownListLines } from "@/lib/list-guard";
import { passesListRepairSafetyCheck, repairListFormatting } from "@/lib/list-repair";

describe("needsListRepair / hasMarkdownListLines (detector)", () => {
  it("fires on a mixed zh/en implicit list with no Markdown yet (the observed SMART gap)", () => {
    expect(needsListRepair("有几个 action items：更新 README，加 unit tests，然后 deploy 到 staging。")).toBe(true);
  });

  it("fires on the coordinator's list-intro example (以下几个要点 + 3 clauses, no colon)", () => {
    expect(needsListRepair("我们讲一下以下几个要点，新版本周二上线，客服要提前培训，监控要加延迟指标")).toBe(true);
  });

  it("fires on 2+ enumeration cues even without a list-intro cue", () => {
    expect(needsListRepair("first we update the docs, second we fix the bug, finally we deploy")).toBe(true);
  });

  it("does NOT fire when the text already has a Markdown list", () => {
    expect(needsListRepair("以下几个要点：\n- 新版本上线\n- 客服培训\n- 监控指标")).toBe(false);
    expect(needsListRepair("Steps:\n1. Open settings\n2. Click account\n3. Sign out")).toBe(false);
  });

  it("does NOT fire on a narrative sentence with 、 and 和 but no list-intro cue (the coordinator's exact negative example)", () => {
    // "I went to the store today and bought apples, bananas, and milk" —
    // has a 、 and a 和, but no colon and no list-intro cue (以下/几点/几个/
    // 几件/action items/points/things/steps/items), so it must not fire
    // even though multiple items are enumerated.
    expect(needsListRepair("我今天去了超市，买了苹果、香蕉和牛奶")).toBe(false);
  });

  it("does NOT fire on a single point", () => {
    expect(needsListRepair("今天天气不错，我们出去走走吧。")).toBe(false);
  });

  it("hasMarkdownListLines detects both bullet and numbered lines, and rejects prose", () => {
    expect(hasMarkdownListLines("- one\n- two")).toBe(true);
    expect(hasMarkdownListLines("1. one\n2. two")).toBe(true);
    expect(hasMarkdownListLines("just a sentence, with a comma")).toBe(false);
  });
});

describe("passesListRepairSafetyCheck", () => {
  it("passes when only layout/punctuation/connectors changed", () => {
    const original = "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。";
    const repaired = "有几个 action items：\n- 更新 readme\n- 加 unit tests\n- deploy 到 staging";
    expect(passesListRepairSafetyCheck(original, repaired)).toBe(true);
  });

  it("passes with only a case difference in Latin text", () => {
    expect(passesListRepairSafetyCheck("update readme, fix bug", "- Update Readme\n- Fix Bug")).toBe(true);
  });

  it("rejects when the model changes a word", () => {
    const original = "有几个 action items，更新 readme，加 unit tests";
    const repaired = "有几个 action items：\n- 更新 documentation\n- 加 unit tests"; // "readme" -> "documentation"
    expect(passesListRepairSafetyCheck(original, repaired)).toBe(false);
  });

  it("rejects when the model translates the content", () => {
    const original = "有几个 action items，更新 readme，加 unit tests";
    const repaired = "- Update the readme\n- Add unit tests"; // translated to English, dropped 有几个/action items(CJK context)
    expect(passesListRepairSafetyCheck(original, repaired)).toBe(false);
  });

  it("rejects when the model adds new content", () => {
    const original = "有几个 action items，更新 readme，加 unit tests";
    const repaired = "- 更新 readme\n- 加 unit tests\n- 部署到生产环境"; // invented a 3rd item
    expect(passesListRepairSafetyCheck(original, repaired)).toBe(false);
  });

  it("rejects when the model drops content", () => {
    const original = "有几个 action items，更新 readme，加 unit tests，然后 deploy";
    const repaired = "- 更新 readme\n- 加 unit tests"; // dropped "deploy"
    expect(passesListRepairSafetyCheck(original, repaired)).toBe(false);
  });
});

describe("repairListFormatting", () => {
  beforeEach(() => {
    generateTextMock.mockReset();
  });

  it("does not call the model at all when the detector doesn't fire", async () => {
    const result = await repairListFormatting("好的，收到，谢谢。");
    expect(result.formatRepair).toBeNull();
    expect(result.text).toBe("好的，收到，谢谢。");
    expect(generateTextMock).not.toHaveBeenCalled();
  });

  it("applies the repair when the model's output passes the safety check", async () => {
    generateTextMock.mockResolvedValue({
      text: "有几个 action items：\n* 更新 readme\n* 加 unit tests\n* deploy 到 staging",
    });
    const result = await repairListFormatting("有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。");
    expect(result.formatRepair).toBe("applied");
    // The '*' markers from the mocked model output are also normalized to '-'.
    expect(result.text).toBe("有几个 action items：\n- 更新 readme\n- 加 unit tests\n- deploy 到 staging");
    expect(generateTextMock).toHaveBeenCalledTimes(1);
    const call = generateTextMock.mock.calls[0]![0];
    expect(call.model).toEqual({ modelId: "openai/gpt-6-luna" });
    expect(call.providerOptions).toEqual({ openai: { reasoningEffort: "none" } });
    expect(call.temperature).toBeUndefined(); // luna rejects temperature
  });

  it("rejects and keeps the original when the model changes content", async () => {
    generateTextMock.mockResolvedValue({
      text: "- Update the readme\n- Add unit tests\n- Deploy to staging", // translated
    });
    const original = "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。";
    const result = await repairListFormatting(original);
    expect(result.formatRepair).toBe("rejected");
    expect(result.text).toBe(original);
  });

  it("times out and keeps the original when the model doesn't respond within 2s", async () => {
    vi.useFakeTimers();
    generateTextMock.mockImplementation(
      ({ abortSignal }: { abortSignal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          abortSignal?.addEventListener("abort", () => reject(new Error("aborted")));
        })
    );
    const original = "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。";
    const pending = repairListFormatting(original);
    await vi.advanceTimersByTimeAsync(2000);
    const result = await pending;
    expect(result.formatRepair).toBe("timeout");
    expect(result.text).toBe(original);
    vi.useRealTimers();
  });

  it("treats a non-timeout model error as rejected, keeping the original", async () => {
    generateTextMock.mockRejectedValue(new Error("upstream boom"));
    const original = "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。";
    const result = await repairListFormatting(original);
    expect(result.formatRepair).toBe("rejected");
    expect(result.text).toBe(original);
  });
});
