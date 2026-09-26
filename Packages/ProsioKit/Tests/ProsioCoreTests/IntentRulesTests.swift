import Testing
@testable import ProsioCore

@Suite struct IntentRulesTests {

    private let defaultTarget = "en-US"

    // MARK: - Ask: positives

    @Test func askChineseWithColon() {
        let result = IntentRules.classify("提问：怎么撤销 commit", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askChineseWithYixiaThenComma() {
        let result = IntentRules.classify("提问一下，今天星期几", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askChineseYixiaAlone() {
        let result = IntentRules.classify("问一下现在几点", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askChineseQingjiao() {
        let result = IntentRules.classify("请教，这个怎么用", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askChineseInterrogativeBodyWithoutSeparator() {
        // "提问怎么撤销commit" — no punctuation/一下, but "怎么" satisfies "a question body".
        let result = IntentRules.classify("提问怎么撤销commit", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askProsioWakeWord() {
        let result = IntentRules.classify("Prosio，今天天气怎么样", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askEnglishQuestionComma() {
        let result = IntentRules.classify("Question, what time is it", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askEnglishQuickQuestionColon() {
        let result = IntentRules.classify("quick question: how do I revert a commit", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    @Test func askEnglishHeyProsio() {
        let result = IntentRules.classify("hey Prosio, what's the weather", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .ask)
    }

    // MARK: - Ask: negatives

    @Test func askNegative_huidaDeHenHao() {
        // "回答得很好，谢谢" — 回答 followed by 得 (not 一下/separator/interrogative) -> not ask.
        let result = IntentRules.classify("回答得很好，谢谢", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    @Test func askNegative_tiwenHuanjie() {
        // "提问环节在下午三点" — 提问 followed by 环 -> not ask.
        let result = IntentRules.classify("提问环节在下午三点", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    @Test func askNegative_notAtStart() {
        let result = IntentRules.classify("我提问一下", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    @Test func askNegative_qingwenNeverMatches() {
        let result = IntentRules.classify("请问现在几点了", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    @Test func askNegative_bareAskNeverMatches() {
        let result = IntentRules.classify("Ask her to call me back", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    @Test func askNegative_bareQuestionWithoutSeparator() {
        let result = IntentRules.classify("question is whether this works", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .ask)
    }

    // MARK: - Translate: positives

    @Test func translateChineseChengWithColon() {
        let result = IntentRules.classify("翻译成英文：你好世界", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "en-US")
        #expect(result.translateBody == "你好世界")
    }

    @Test func translateChineseFanchengShortForm() {
        let result = IntentRules.classify("翻成日语，你好", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "ja-JP")
        #expect(result.translateBody == "你好")
    }

    @Test func translateChineseYichengShortForm() {
        let result = IntentRules.classify("译成法语：晚安", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "fr-FR")
        #expect(result.translateBody == "晚安")
    }

    @Test func translateChineseBangwoFanyi() {
        let result = IntentRules.classify("帮我翻译成韩语：谢谢", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "ko-KR")
        #expect(result.translateBody == "谢谢")
    }

    @Test func translateChineseBareUsesDefault() {
        let result = IntentRules.classify("翻译，你好", hasSelection: false, defaultTranslateTarget: "zh-CN")
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "zh-CN")
        #expect(result.translateBody == "你好")
    }

    @Test func translateChineseYongShuoPattern() {
        let result = IntentRules.classify("用英文说，你好", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "en-US")
        #expect(result.translateBody == "你好")
    }

    @Test func translateEnglishToLanguageColon() {
        let result = IntentRules.classify("Translate to French: Hello, how are you", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "fr-FR")
        #expect(result.translateBody == "Hello, how are you")
    }

    @Test func translateEnglishThisIntoLanguage() {
        let result = IntentRules.classify("Translate this into Spanish, good morning", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "es-ES")
        #expect(result.translateBody == "good morning")
    }

    @Test func translateEnglishBareUsesDefault() {
        let result = IntentRules.classify("Translate: see you soon", hasSelection: false, defaultTranslateTarget: "ja-JP")
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "ja-JP")
        #expect(result.translateBody == "see you soon")
    }

    @Test func translateEnglishInLanguagePattern() {
        let result = IntentRules.classify("In Japanese, see you tomorrow", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
        #expect(result.translateTarget == "ja-JP")
        #expect(result.translateBody == "see you tomorrow")
    }

    // MARK: - Translate: negatives

    @Test func translateNegative_noSeparatorNoYixia() {
        let result = IntentRules.classify("翻译你好", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .translate)
    }

    @Test func translateNegative_emptyBody() {
        let result = IntentRules.classify("翻译成英文：", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .translate)
    }

    @Test func translateNegative_mentionedNotRequested() {
        // "translation" merely mentioned mid-sentence, not a command at the start.
        let result = IntentRules.classify("I need a translation of this document later", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .translate)
    }

    // MARK: - Default fallback

    @Test func defaultIsDictateWithoutSelection() {
        let result = IntentRules.classify("just a normal dictation with no cues", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .dictate)
        #expect(result.translateTarget == nil)
        #expect(result.translateBody == nil)
    }

    @Test func defaultIsEditWithSelection() {
        let result = IntentRules.classify("make this shorter", hasSelection: true, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .edit)
    }

    @Test func translateCueWinsOverSelectionDefault() {
        // Even with a selection present, an explicit translate cue still wins.
        let result = IntentRules.classify("翻译成英文：你好", hasSelection: true, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .translate)
    }
}
