// Mechanical drift check: every line inside a fenced code block in
// docs/PROMPTS.md (the source of truth) must appear, verbatim, in
// lib/prompts.ts's source — this is exactly the kind of check that would
// have caught the missed "Never add reasons, facts, ..." rule (docs/PROMPTS.md
// §3, tightened after a live acceptance found Edit mode inventing a reason).
//
// For lines containing a `{placeholder}`, we can't require the literal
// `{name}` text (prompts.ts renders it via real interpolation, not
// string-replace), so we instead require every literal fragment AROUND the
// placeholder(s) to appear — e.g. "Where: {appName}{ — windowTitle}. Scene:
// {scene}." requires "Where:", "Scene:", and "." to each appear in the
// source. Placeholder-free lines (the bulk of the rule text, and the class
// of line that actually drifted) get the strict full-line check.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const __dirname = dirname(fileURLToPath(import.meta.url));
const promptsDoc = readFileSync(join(__dirname, "../../docs/PROMPTS.md"), "utf8");
const promptsSource = readFileSync(join(__dirname, "../lib/prompts.ts"), "utf8");

function extractFencedBlocks(markdown: string): string[] {
  const blocks: string[] = [];
  const re = /```\n([\s\S]*?)\n```/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(markdown))) blocks.push(m[1]!);
  return blocks;
}

const blocks = extractFencedBlocks(promptsDoc);
const allLines = blocks.flatMap((b) => b.split("\n")).filter((l) => l.trim().length > 0);

describe("docs/PROMPTS.md verbatim check", () => {
  it("found a plausible number of template lines to check (sanity guard against a regex that stops matching)", () => {
    expect(allLines.length).toBeGreaterThan(25);
  });

  it.each(allLines)("appears in lib/prompts.ts: %s", (line) => {
    if (!line.includes("{")) {
      expect(promptsSource).toContain(line);
      return;
    }
    const fragments = line
      .split(/\{[^}]*\}/)
      .map((f) => f.trim())
      .filter((f) => f.length > 0);
    for (const frag of fragments) {
      expect(promptsSource).toContain(frag);
    }
  });
});
