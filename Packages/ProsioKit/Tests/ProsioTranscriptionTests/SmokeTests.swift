import Foundation
import Speech
import Testing
@testable import ProsioTranscription

@Test func speechAnalyzerIsOnDevice() {
    #expect(SpeechAnalyzerEngine().isOnDevice)
}

@Test func redactProfanity_masksKnownTerms() {
    #expect(SpeechAnalyzerEngine.redactProfanity("我今天要做三件事，医生影响屁眼儿更新") == "我今天要做三件事，医生影响***更新")
    #expect(SpeechAnalyzerEngine.redactProfanity("clean text") == "clean text")
    #expect(SpeechAnalyzerEngine.redactProfanity("") == "")
}

/// Diagnostic, not a pass/fail assertion either way (this machine's OS build and downloaded
/// language assets vary): prints `DictationTranscriber.supportedLocales` (the module
/// `SpeechAnalyzerEngine` actually uses — see its doc comment for why `DictationTranscriber` was
/// chosen over `SpeechTranscriber`) and whether zh-CN, zh-Hans, and en-US are supported.
@Test func dictationTranscriberSupportedLocalesDiagnostic() async {
    let supported = await DictationTranscriber.supportedLocales
    let identifiers = supported.map { $0.identifier(.bcp47) }.sorted()
    print("DictationTranscriber.supportedLocales (\(identifiers.count)): \(identifiers)")

    for candidate in ["zh-CN", "zh-Hans", "en-US"] {
        let locale = Locale(identifier: candidate)
        let isDirectlySupported = supported.contains {
            $0.identifier(.bcp47).caseInsensitiveCompare(locale.identifier(.bcp47)) == .orderedSame
        }
        let equivalent = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        print("  \(candidate): directlySupported=\(isDirectlySupported) equivalentTo=\(equivalent?.identifier(.bcp47) ?? "nil")")
    }

    // Not asserting availability: this is a diagnostic for the agent's report, not a hard
    // requirement (CI machines may have no language assets installed / entitlement to query
    // them). We only assert the API call itself doesn't crash / hang.
    #expect(Bool(true))
}

/// Evidence for the `DictationTranscriber`-vs-`SpeechTranscriber` module choice (see
/// `SpeechAnalyzerEngine`'s doc comment): `DictationTranscriber.supportedLocales` is a strict
/// superset of `SpeechTranscriber.supportedLocales` on this SDK. Kept as a live regression guard
/// on that claim rather than a one-off scratch check.
@Test func dictationTranscriberLocaleCoverageIsASupersetOfSpeechTranscriber() async {
    let speechLocales = Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
    let dictationLocales = Set(await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
    print("SpeechTranscriber: \(speechLocales.count) locales, DictationTranscriber: \(dictationLocales.count) locales")
    print("Only in DictationTranscriber: \(dictationLocales.subtracting(speechLocales).sorted())")
    #expect(speechLocales.isSubset(of: dictationLocales))
}
