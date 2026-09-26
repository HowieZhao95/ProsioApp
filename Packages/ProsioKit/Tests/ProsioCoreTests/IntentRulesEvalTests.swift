import Foundation
import Testing
@testable import ProsioCore

/// Runs the client-side `IntentRules` fallback against the shared labelled eval set
/// (`eval/intent-cases.json`, 78 cases covering en/zh/ja/es/fr/ko/mixed) that the server team
/// also evaluates Jev against. `IntentRules` is the *degraded* path (Jev unavailable/timeout/nil),
/// so it is not held to Jev's accuracy bar — but a false command (rules turning an ordinary
/// dictation/edit into an ask or translate) is a hard failure, since that's a silent hijack of the
/// user's dictated text. Misses on genuine ask/translate cases are acceptable and only reported.
@Suite struct IntentRulesEvalTests {
    private struct EvalCase: Decodable {
        let id: String
        let language: String
        let hasSelection: Bool
        let transcript: String
        let expected: String
        let note: String?
    }

    /// `eval/intent-cases.json` lives at the repo root; this test file is 5 directories below it
    /// (ProsioCoreTests/Tests/ProsioKit/Packages/ProsioApp), resolved from `#filePath` so it works
    /// regardless of the machine's checkout location.
    private static func loadCases() throws -> [EvalCase] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProsioCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ProsioKit/
            .deletingLastPathComponent() // Packages/
            .deletingLastPathComponent() // ProsioApp/ (repo root)
        let url = repoRoot.appendingPathComponent("eval/intent-cases.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([EvalCase].self, from: data)
    }

    @Test func evalAgainstLabelledCases() throws {
        let cases = try Self.loadCases()
        #expect(cases.count >= 70, "expected the full eval/intent-cases.json set, got \(cases.count)")

        var falseCommands: [String] = []
        var askTotal = 0, askHits = 0
        var translateTotal = 0, translateHits = 0

        for testCase in cases {
            let result = IntentRules.classify(
                testCase.transcript,
                hasSelection: testCase.hasSelection,
                defaultTranslateTarget: "en-US"
            )

            switch testCase.expected {
            case "dictate", "edit":
                if result.intent == .ask || result.intent == .translate {
                    falseCommands.append(
                        "\(testCase.id) [\(testCase.language)]: expected \(testCase.expected), IntentRules said \(result.intent) for \"\(testCase.transcript)\""
                    )
                }
            case "ask":
                askTotal += 1
                if result.intent == .ask { askHits += 1 }
            case "translate":
                translateTotal += 1
                if result.intent == .translate { translateHits += 1 }
            default:
                break
            }
        }

        let askAccuracy = askTotal > 0 ? Double(askHits) / Double(askTotal) * 100 : 0
        let translateAccuracy = translateTotal > 0 ? Double(translateHits) / Double(translateTotal) * 100 : 0
        print(
            """
            IntentRules eval (degraded-path fallback, not held to Jev's bar):
              ask:       \(askHits)/\(askTotal) (\(String(format: "%.1f", askAccuracy))%)
              translate: \(translateHits)/\(translateTotal) (\(String(format: "%.1f", translateAccuracy))%)
              false commands on dictate/edit cases: \(falseCommands.count)
            """
        )

        #expect(
            falseCommands.isEmpty,
            "IntentRules produced a false command (ask/translate) on \(falseCommands.count) dictate/edit case(s):\n\(falseCommands.joined(separator: "\n"))"
        )
    }
}
