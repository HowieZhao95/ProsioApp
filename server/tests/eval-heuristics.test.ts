import { describe, expect, it } from "vitest";
import { runHeuristics } from "@/lib/eval/heuristics";
import type { EvalCase } from "@/lib/eval/types";

function kase(overrides: Partial<EvalCase>): EvalCase {
  return {
    id: "test",
    category: "filler",
    language: "en",
    script: "script",
    expected: "expected",
    vocabulary: [],
    ...overrides,
  };
}

describe("runHeuristics", () => {
  it("filler: fails when a filler token leaks into the hypothesis", () => {
    const results = runHeuristics(kase({ category: "filler" }), "um, I think this is fine");
    expect(results.find((r) => r.name === "fillers-absent")?.passed).toBe(false);
  });

  it("filler: passes on a clean hypothesis", () => {
    const results = runHeuristics(kase({ category: "filler" }), "I think this is fine");
    expect(results.find((r) => r.name === "fillers-absent")?.passed).toBe(true);
  });

  it("filler: does not flag meaningful words that merely contain filler substrings", () => {
    // "erm" must not match inside "term", "umm" must not match inside "yummy", etc.
    const results = runHeuristics(kase({ category: "filler" }), "the term is yummy and permanent");
    expect(results.find((r) => r.name === "fillers-absent")?.passed).toBe(true);
  });

  it("self-correction: fails when a correction marker leaks", () => {
    const results = runHeuristics(
      kase({ category: "self-correction" }),
      "会议改到明天上午十点，不对，是十点半"
    );
    expect(results.find((r) => r.name === "correction-resolved")?.passed).toBe(false);
  });

  it("self-correction: passes once the correction is resolved", () => {
    const results = runHeuristics(kase({ category: "self-correction" }), "会议改到明天上午十点半");
    expect(results.find((r) => r.name === "correction-resolved")?.passed).toBe(true);
  });

  it("list: passes when numbered lines match the expected shape", () => {
    const expected = "Steps:\n1. a\n2. b\n3. c";
    const results = runHeuristics(kase({ category: "list", expected }), "Steps:\n1. a\n2. b\n3. c");
    expect(results.find((r) => r.name === "list-formatted")?.passed).toBe(true);
  });

  it("list: fails when the hypothesis is a run-on sentence", () => {
    const expected = "Steps:\n1. a\n2. b\n3. c";
    const results = runHeuristics(kase({ category: "list", expected }), "a then b then c");
    expect(results.find((r) => r.name === "list-formatted")?.passed).toBe(false);
  });

  it("code-switch: passes only when both scripts are present for mixed-language cases", () => {
    const c = kase({ category: "code-switch", language: "mixed" });
    expect(runHeuristics(c, "这个 PR 已经 deploy 了").find((r) => r.name === "mixed-script-preserved")?.passed).toBe(
      true
    );
    expect(runHeuristics(c, "这个已经部署了").find((r) => r.name === "mixed-script-preserved")?.passed).toBe(false);
  });

  it("names-jargon: fails when a vocabulary term is missing", () => {
    const c = kase({ category: "names-jargon", vocabulary: ["Kevin", "Jira"] });
    const results = runHeuristics(c, "assign this to someone and track it somewhere");
    expect(results.find((r) => r.name === "vocabulary-honored")?.passed).toBe(false);
  });

  it("names-jargon: passes when every vocabulary term appears", () => {
    const c = kase({ category: "names-jargon", vocabulary: ["Kevin", "Jira"] });
    const results = runHeuristics(c, "assign this to Kevin and track it in Jira");
    expect(results.find((r) => r.name === "vocabulary-honored")?.passed).toBe(true);
  });

  it("punctuation: fails on an unpunctuated run-on", () => {
    const expected = "Are you free? If so, let's meet.";
    const results = runHeuristics(kase({ category: "punctuation", expected }), "are you free if so lets meet");
    expect(results.find((r) => r.name === "punctuated")?.passed).toBe(false);
  });

  it("long-form: fails when the output is drastically truncated", () => {
    const expected = "a".repeat(200);
    const results = runHeuristics(kase({ category: "long-form", expected }), "short");
    expect(results.find((r) => r.name === "length-in-range")?.passed).toBe(false);
  });
});
