import { describe, expect, it } from "vitest";
import { needsFormattingGuard } from "@/lib/list-guard";

describe("needsFormattingGuard", () => {
  it("triggers on the coordinator's exact example (list-intro cue + clauses, no colon)", () => {
    const result = needsFormattingGuard("我们讲一下以下几个要点，新版本周二上线，客服要提前培训，监控要加延迟指标");
    expect(result.triggered).toBe(true);
    expect(result.listLikeClauseCount).toBeGreaterThanOrEqual(3);
  });

  it("triggers on 3 Chinese enumeration cues (第一/第二/第三)", () => {
    const result = needsFormattingGuard("第一，新版本周二上线。第二，客服要提前培训。第三，监控要加延迟指标。");
    expect(result.triggered).toBe(true);
    expect(result.enumerationCueCount).toBeGreaterThanOrEqual(2);
  });

  it("triggers on 2 Chinese enumeration cues (首先/最后)", () => {
    const result = needsFormattingGuard("首先，会议改到下午三点。最后，记得带电脑。");
    expect(result.triggered).toBe(true);
  });

  it("triggers on English enumeration cues (first/second/finally)", () => {
    const result = needsFormattingGuard(
      "let me go over a few things first we need to update the docs second we need to fix the bug and finally deploy"
    );
    expect(result.triggered).toBe(true);
    expect(result.enumerationCueCount).toBeGreaterThanOrEqual(2);
  });

  it("triggers on mixed zh/en enumeration cues", () => {
    const result = needsFormattingGuard("跟你说几个 points，first 这个 feature 要上线了，second QA 还没测完，third deadline 可能要往后推");
    expect(result.triggered).toBe(true);
  });

  it("triggers on a colon followed by >=3 comma-separated clauses with a list-intro cue", () => {
    const result = needsFormattingGuard("跟大家说几件事：会议改到下午三点，报告要提前交，记得带电脑");
    expect(result.triggered).toBe(true);
    expect(result.listLikeClauseCount).toBeGreaterThanOrEqual(3);
  });

  it("does NOT trigger on a plain narrative sentence with commas (no enumeration cues, no list-intro cue)", () => {
    const result = needsFormattingGuard("我今天去了超市，买了牛奶，然后回家做饭了");
    expect(result.triggered).toBe(false);
  });

  it("does NOT trigger on a single point with no commas at all", () => {
    const result = needsFormattingGuard("今天天气不错，我们出去走走吧");
    expect(result.triggered).toBe(false);
  });

  it("does NOT trigger on only 1 enumeration cue", () => {
    const result = needsFormattingGuard("first we need to update the docs, then ship it");
    expect(result.triggered).toBe(false);
  });

  it("does NOT trigger on only 2 comma-separated clauses even with a colon", () => {
    const result = needsFormattingGuard("todo: buy milk, pay the bill");
    expect(result.triggered).toBe(false);
  });

  it("does NOT false-positive on an unrelated word containing an enumeration cue as a substring (e.g. 'firstname')", () => {
    const result = needsFormattingGuard("please update the firstname field and the nextel account number");
    expect(result.enumerationCueCount).toBe(0);
    expect(result.triggered).toBe(false);
  });

  it("word-boundary matching still catches 'first' and 'next' as whole words", () => {
    const result = needsFormattingGuard("first check the logs, next restart the service");
    expect(result.enumerationCueCount).toBe(2);
  });
});
