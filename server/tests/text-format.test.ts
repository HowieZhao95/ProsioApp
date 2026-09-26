import { describe, expect, it } from "vitest";
import { normalizeListMarkers } from "@/lib/text-format";

describe("normalizeListMarkers", () => {
  it("normalizes a line-start asterisk bullet to a dash", () => {
    expect(normalizeListMarkers("* first\n* second")).toBe("- first\n- second");
  });

  it("normalizes a bullet character (•) to a dash", () => {
    expect(normalizeListMarkers("• first\n• second")).toBe("- first\n- second");
  });

  it("normalizes a middle dot (·) to a dash", () => {
    expect(normalizeListMarkers("· first\n· second")).toBe("- first\n- second");
  });

  it("normalizes an en dash (–) to a dash", () => {
    expect(normalizeListMarkers("– first\n– second")).toBe("- first\n- second");
  });

  it("collapses extra whitespace after the marker to a single space", () => {
    expect(normalizeListMarkers("*   padded item")).toBe("- padded item");
  });

  it("leaves an already-correct '- ' bullet unchanged", () => {
    expect(normalizeListMarkers("- already correct")).toBe("- already correct");
  });

  it("leaves numbered markers ('1. ', '2. ') untouched", () => {
    const text = "1. first\n2. second\n3. third";
    expect(normalizeListMarkers(text)).toBe(text);
  });

  it("normalizes indented (nested) bullets, preserving the indentation", () => {
    expect(normalizeListMarkers("  * nested item")).toBe("  - nested item");
  });

  it("does not touch mid-line '**bold**' emphasis", () => {
    const text = "This is **bold** text.";
    expect(normalizeListMarkers(text)).toBe(text);
  });

  it("does not touch a line starting with '**bold**' (double-asterisk emphasis, not a list marker)", () => {
    const text = "**Important:** please read this.";
    expect(normalizeListMarkers(text)).toBe(text);
  });

  it("does not touch a whole line wrapped in single-asterisk italics (no space after the asterisk)", () => {
    const text = "*Note: this is important*";
    expect(normalizeListMarkers(text)).toBe(text);
  });

  it("normalizes the marker but leaves inline emphasis within the list item alone", () => {
    expect(normalizeListMarkers("* *emphasis* stays here")).toBe("- *emphasis* stays here");
  });

  it("never touches any line inside a fenced code block, including markers that look like bullets", () => {
    const text = ["Some text:", "```", "* not a bullet, this is code", "- also code", "```", "* this IS a bullet"].join("\n");
    const expected = ["Some text:", "```", "* not a bullet, this is code", "- also code", "```", "- this IS a bullet"].join("\n");
    expect(normalizeListMarkers(text)).toBe(expected);
  });

  it("does not toggle fence state on a mid-line triple-backtick (only line-start fences count)", () => {
    // Defensive: a fence delimiter is only recognized at (optionally indented) line start.
    const text = "before\n* bullet after fenced-looking text but not a real fence";
    expect(normalizeListMarkers(text)).toBe("before\n- bullet after fenced-looking text but not a real fence");
  });

  it("handles a fenced block that starts with a language tag", () => {
    const text = ["```ts", "* not code, but inside the fence", "```", "* real bullet"].join("\n");
    const expected = ["```ts", "* not code, but inside the fence", "```", "- real bullet"].join("\n");
    expect(normalizeListMarkers(text)).toBe(expected);
  });

  it("leaves plain prose with no list markers completely unchanged", () => {
    const text = "This is just a normal sentence, with a comma, and another.";
    expect(normalizeListMarkers(text)).toBe(text);
  });

  it("handles a mix of bullet styles and numbered items in one text", () => {
    const text = ["Intro line:", "* first", "• second", "1. numbered stays", "· fourth"].join("\n");
    const expected = ["Intro line:", "- first", "- second", "1. numbered stays", "- fourth"].join("\n");
    expect(normalizeListMarkers(text)).toBe(expected);
  });
});
