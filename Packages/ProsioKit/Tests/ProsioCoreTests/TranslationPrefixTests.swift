import Testing
@testable import ProsioCore

@Suite struct TranslationPrefixTests {

    @Test func chineseTranslateToEnglishWithFullWidthColon() {
        let result = TranslationPrefix.parse("翻译成英文：你好世界")
        #expect(result?.targetLanguage == "en-US")
        #expect(result?.remainder == "你好世界")
    }

    @Test func chineseShortPrefixWithComma() {
        let result = TranslationPrefix.parse("译成日语，你好")
        #expect(result?.targetLanguage == "ja-JP")
        #expect(result?.remainder == "你好")
    }

    @Test func chineseToChineseSimplified() {
        let result = TranslationPrefix.parse("翻译成中文：Hello there")
        #expect(result?.targetLanguage == "zh-CN")
        #expect(result?.remainder == "Hello there")
    }

    @Test func englishTranslateTo() {
        let result = TranslationPrefix.parse("Translate to French: Hello, how are you")
        #expect(result?.targetLanguage == "fr-FR")
        #expect(result?.remainder == "Hello, how are you")
    }

    @Test func englishTranslateThisInto() {
        let result = TranslationPrefix.parse("Translate this into Spanish, good morning")
        #expect(result?.targetLanguage == "es-ES")
        #expect(result?.remainder == "good morning")
    }

    @Test func englishTranslateItToIsCaseInsensitive() {
        let result = TranslationPrefix.parse("TRANSLATE IT TO japanese: hello")
        #expect(result?.targetLanguage == "ja-JP")
        #expect(result?.remainder == "hello")
    }

    @Test func noPrefixReturnsNil() {
        #expect(TranslationPrefix.parse("just a normal dictation") == nil)
        #expect(TranslationPrefix.parse("你好，今天天气不错") == nil)
    }

    @Test func prefixOnlyInTheMiddleDoesNotMatch() {
        #expect(TranslationPrefix.parse("please 翻译成英文：你好 for me") == nil)
    }

    @Test func languageNameWithoutSeparatorDoesNotMatch() {
        // No colon/comma right after the language name -> not recognized (per spec: separators
        // are required, bare whitespace alone doesn't count).
        #expect(TranslationPrefix.parse("翻译成英文 你好世界") == nil)
        #expect(TranslationPrefix.parse("Translate to French hello") == nil)
    }

    @Test func unmappedLanguageNameDoesNotMatch() {
        #expect(TranslationPrefix.parse("翻译成火星语：你好") == nil)
    }

    @Test func emptyRemainderStillParses() {
        // Parsing succeeds; callers are expected to treat an empty remainder as "not usable".
        let result = TranslationPrefix.parse("翻译成英文：")
        #expect(result?.targetLanguage == "en-US")
        #expect(result?.remainder == "")
    }
}
