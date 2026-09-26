import { describe, expect, it } from "vitest";
import {
  buildAskPrompt,
  buildEditPrompt,
  buildRewritePrompt,
  buildTranslateCommandPrompt,
  buildTranslatePrompt,
  languageNameFromBCP47,
  sanitizeComposeOutput,
} from "@/lib/prompts";

describe("buildRewritePrompt", () => {
  it("email scene, with vocabulary and a window title", () => {
    const prompt = buildRewritePrompt({
      transcript: "hey just wanted to say the meeting moved to thursday",
      scene: "email",
      app: { appName: "Mail", windowTitle: "New Message" },
      vocabulary: ["Prosio", "Kevin"],
    });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([
      { role: "user", content: "<dictation>\nhey just wanted to say the meeting moved to thursday\n</dictation>" },
    ]);
  });

  it("chat scene, no vocabulary, no app (fallback + line omitted)", () => {
    const prompt = buildRewritePrompt({ transcript: "x", scene: "chat" });
    expect(prompt.system).toMatchSnapshot();
  });

  it("code scene", () => {
    expect(buildRewritePrompt({ transcript: "x", scene: "code", app: { appName: "Terminal" } }).system).toMatchSnapshot();
  });

  it("document scene", () => {
    expect(buildRewritePrompt({ transcript: "x", scene: "document" }).system).toMatchSnapshot();
  });

  it("general scene: no scene-rules block", () => {
    const prompt = buildRewritePrompt({ transcript: "x", scene: "general", app: { appName: "Notes" } });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.system).not.toContain("Scene rules");
  });
});

describe("buildTranslatePrompt", () => {
  it("zh-CN target, email scene, with app (sceneHint present)", () => {
    const prompt = buildTranslatePrompt({
      transcript: "你好，最近怎么样？",
      targetLanguage: "zh-CN",
      scene: "email",
      app: { appName: "Mail" },
    });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([{ role: "user", content: "<text>\n你好，最近怎么样？\n</text>" }]);
  });

  it("ja target, general scene: no sceneHint line", () => {
    const prompt = buildTranslatePrompt({ transcript: "hi", targetLanguage: "ja" });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.system).not.toContain("will be typed into");
  });

  it("en-US target, with vocabulary", () => {
    expect(
      buildTranslatePrompt({ transcript: "帮我查一下 Prosio 的文档", targetLanguage: "en-US", vocabulary: ["Prosio"] }).system
    ).toMatchSnapshot();
  });
});

describe("buildTranslateCommandPrompt", () => {
  it("default language, no vocabulary", () => {
    const prompt = buildTranslateCommandPrompt({ transcript: "帮我翻成日语：我们明天开会", defaultLanguage: "en-US" });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([{ role: "user", content: "<utterance>\n帮我翻成日语：我们明天开会\n</utterance>" }]);
  });

  it("with vocabulary", () => {
    expect(
      buildTranslateCommandPrompt({ transcript: "translate to Spanish, see you soon", defaultLanguage: "en-US", vocabulary: ["Prosio"] })
        .system
    ).toMatchSnapshot();
  });
});

describe("buildEditPrompt", () => {
  it("with vocabulary", () => {
    const prompt = buildEditPrompt({ selection: "foo bar baz", instruction: "make it shorter", vocabulary: ["Prosio"] });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([
      { role: "user", content: "<selected_text>\nfoo bar baz\n</selected_text>\n<instruction>\nmake it shorter\n</instruction>" },
    ]);
  });

  it("without vocabulary", () => {
    expect(buildEditPrompt({ selection: "x", instruction: "y" }).system).toMatchSnapshot();
  });
});

describe("buildAskPrompt", () => {
  it("with app, selection, and history", () => {
    const prompt = buildAskPrompt({
      question: "what does this mean?",
      app: { appName: "Safari", windowTitle: "Example — Docs" },
      selection: "const x = 1;",
      history: [
        { role: "user", text: "hi" },
        { role: "assistant", text: "hello!" },
      ],
    });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello!" },
      { role: "user", content: "what does this mean?" },
    ]);
  });

  it("no app, no selection, no history", () => {
    const prompt = buildAskPrompt({ question: "hi" });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.messages).toEqual([{ role: "user", content: "hi" }]);
  });

  it("with app but no selection: no context block", () => {
    const prompt = buildAskPrompt({ question: "hi", app: { appName: "Terminal" } });
    expect(prompt.system).toMatchSnapshot();
    expect(prompt.system).not.toContain("<context>");
  });
});

describe("languageNameFromBCP47", () => {
  it.each([
    ["en-US", "English"],
    ["en", "English"],
    ["zh-CN", "Simplified Chinese"],
    ["zh-Hans", "Simplified Chinese"],
    ["zh-TW", "Traditional Chinese"],
    ["zh-Hant", "Traditional Chinese"],
    ["ja", "Japanese"],
    ["ja-JP", "Japanese"],
    ["ko", "Korean"],
    ["fr", "French"],
  ])("%s -> %s", (tag, expected) => {
    expect(languageNameFromBCP47(tag)).toBe(expected);
  });

  it("falls back to Intl.DisplayNames for an unmapped tag", () => {
    expect(languageNameFromBCP47("nl")).toBe("Dutch");
  });
});

describe("sanitizeComposeOutput", () => {
  it("trims whitespace", () => {
    expect(sanitizeComposeOutput("  hello world  \n")).toBe("hello world");
  });

  it("strips one wrapping pair of double quotes", () => {
    expect(sanitizeComposeOutput('"hello world"')).toBe("hello world");
  });

  it("strips one wrapping pair of curly quotes", () => {
    expect(sanitizeComposeOutput("“hello world”")).toBe("hello world");
  });

  it("does not strip an internal quote that isn't wrapping the whole text", () => {
    expect(sanitizeComposeOutput('He said "hi" to me')).toBe('He said "hi" to me');
  });

  it("strips a single wrapping code fence, including a language tag", () => {
    expect(sanitizeComposeOutput("```ts\nconst x = 1;\n```")).toBe("const x = 1;");
  });

  it("strips a wrapping code fence with no language tag", () => {
    expect(sanitizeComposeOutput("```\nplain text\n```")).toBe("plain text");
  });

  it("only strips ONE wrapping layer, not nested ones", () => {
    expect(sanitizeComposeOutput('"He said \\"hi\\""')).toBe('He said \\"hi\\"');
  });

  it("leaves already-clean text untouched", () => {
    expect(sanitizeComposeOutput("Just a normal sentence.")).toBe("Just a normal sentence.");
  });
});
