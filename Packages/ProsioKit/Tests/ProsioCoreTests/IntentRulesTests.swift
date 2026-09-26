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

    // MARK: - Write ("Help me write"): positives

    @Test func writeChineseBangwoXie() {
        let result = IntentRules.classify("帮我写一封感谢邮件给老王", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseBangwoHuifu() {
        let result = IntentRules.classify("帮我回复他说明天可以，但会晚半小时到", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseBangwoQicao() {
        let result = IntentRules.classify("帮我起草一份会议纪要", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseBangwoNi() {
        let result = IntentRules.classify("帮我拟一份请假条", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseTiwoHui() {
        let result = IntentRules.classify("替我回一下这条消息", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseXieYifeng() {
        let result = IntentRules.classify("写一封邮件给老王，说我下周请三天假", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeChineseQicaoYifeng() {
        let result = IntentRules.classify("起草一封辞职信", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishHelpMeWrite() {
        let result = IntentRules.classify("help me write a follow-up to the client", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishDraftA() {
        let result = IntentRules.classify("draft a resignation letter for me", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishDraftAn() {
        let result = IntentRules.classify("draft an email to the landlord about the leak", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishWriteAReply() {
        let result = IntentRules.classify("write a reply saying we can meet at three", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishWriteAnEmail() {
        let result = IntentRules.classify("write an email to the team about the delay", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeEnglishReplySaying() {
        let result = IntentRules.classify("reply saying thanks, I'll review it tomorrow", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    @Test func writeCueWinsOverSelectionDefault() {
        // A write cue is meaningful even with a selection present (the selection becomes context,
        // not the thing rewritten) — the cue must still be recognized as `.write`, not `.edit`.
        let result = IntentRules.classify("帮我回复说好的没问题", hasSelection: true, defaultTranslateTarget: defaultTarget)
        #expect(result.intent == .write)
    }

    // MARK: - Write: negatives

    @Test func writeNegative_niBangwoNeverMatches() {
        // "你帮我…" is addressed to a person, not a command at the start — must never match.
        let result = IntentRules.classify("你帮我写一下这个方案吧", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .write)
    }

    @Test func writeNegative_notAtStart() {
        let result = IntentRules.classify("我想请你帮我写一封邮件", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .write)
    }

    @Test func writeNegative_mentionedNotRequested() {
        let result = IntentRules.classify("I already wrote a reply to that email yesterday", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .write)
    }

    @Test func writeNegative_writingAboutSomethingElse() {
        let result = IntentRules.classify("write down the address before I forget", hasSelection: false, defaultTranslateTarget: defaultTarget)
        #expect(result.intent != .write)
    }
}
