import { describe, expect, it } from "vitest";
import { characterErrorRate, levenshtein } from "@/lib/eval/cer";

describe("levenshtein", () => {
  it("is 0 for identical strings", () => {
    expect(levenshtein("abc", "abc")).toBe(0);
  });

  it("counts a single substitution", () => {
    expect(levenshtein("abc", "abd")).toBe(1);
  });

  it("handles empty strings", () => {
    expect(levenshtein("", "abc")).toBe(3);
    expect(levenshtein("abc", "")).toBe(3);
    expect(levenshtein("", "")).toBe(0);
  });

  it("is Unicode-code-point aware (CJK characters count as one edit each)", () => {
    expect(levenshtein("你好", "你坏")).toBe(1);
  });
});

describe("characterErrorRate", () => {
  it("is 0 for a perfect (post-normalisation) match", () => {
    const { cer } = characterErrorRate("Hello, World!", "hello world");
    expect(cer).toBe(0);
  });

  it("is 0 when only punctuation/case/whitespace differ", () => {
    const { cer } = characterErrorRate("我们周四下午三点开会，地点在 Room 402。", "我们周四下午三点开会 地点在 room 402");
    expect(cer).toBe(0);
  });

  it("reflects real content differences", () => {
    const { cer, editDistance, referenceLength } = characterErrorRate("我们周三开会", "我们周四开会");
    expect(editDistance).toBe(1);
    expect(referenceLength).toBe(6);
    expect(cer).toBeCloseTo(1 / 6);
  });

  it("caps a fully-empty hypothesis against a non-empty reference at cer 1", () => {
    const { cer } = characterErrorRate("", "some reference text");
    expect(cer).toBe(1);
  });
});
