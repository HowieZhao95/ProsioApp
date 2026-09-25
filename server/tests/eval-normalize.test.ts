import { describe, expect, it } from "vitest";
import { normalizeText } from "@/lib/eval/normalize";

describe("normalizeText", () => {
  it("lowercases, strips punctuation, and collapses whitespace", () => {
    expect(normalizeText("Hello,   World!!")).toBe("hello world");
  });

  it("strips common CJK punctuation", () => {
    expect(normalizeText("你好，世界！这是——测试。")).toBe("你好 世界 这是 测试");
  });

  it("keeps CJK and Latin characters intact side by side", () => {
    expect(normalizeText("这个 PR 已经 deploy 了")).toBe("这个 pr 已经 deploy 了");
  });

  it("trims leading/trailing whitespace", () => {
    expect(normalizeText("  hi  ")).toBe("hi");
  });
});
