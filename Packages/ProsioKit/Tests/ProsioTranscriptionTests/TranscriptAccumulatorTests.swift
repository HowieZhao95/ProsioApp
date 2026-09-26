import Testing
@testable import ProsioTranscription

/// Regression tests for a live bug: `SpeechAnalyzerEngine`'s on-device local final duplicated
/// terminal punctuation at segment join boundaries, e.g.
///
///   "你好，我们现在来再试一下语音输入的一个灵敏度怎么样？？Is cloud doing this station。。"
///
/// (doubled "？？" and "。。") instead of the correct single marks. Root cause: `TranscriptAccumulator`
/// joined finalized segments with plain string concatenation, so a segment ending "...怎么样？"
/// followed by the next segment starting "？Is cloud..." (a `DictationTranscriber` artifact —
/// consecutive segments can each carry the same boundary punctuation) rendered as "？？".
@Suite struct TranscriptAccumulatorTests {
    /// Reproduces the exact reported bug via the exact segments that concatenation would have
    /// combined into the exact reported (buggy) string, and asserts the fixed accumulator instead
    /// produces the correct single-punctuation text.
    @Test func reportedBug_duplicatedPunctuationAtSegmentJoins_isCollapsed() async {
        let accumulator = TranscriptAccumulator()

        // Three finalized segments, as `DictationTranscriber` would deliver them — each carrying
        // its own boundary punctuation, which plain concatenation renders as
        // "...怎么样？？Is cloud doing this station。。" (the exact string reported live).
        _ = await accumulator.applyFinal("你好，我们现在来再试一下语音输入的一个灵敏度怎么样？")
        _ = await accumulator.applyFinal("？Is cloud doing this station。")
        let combined = await accumulator.applyFinal("。")

        let expected = "你好，我们现在来再试一下语音输入的一个灵敏度怎么样？Is cloud doing this station。"
        #expect(combined == expected)
        #expect(!combined.contains("？？"))
        #expect(!combined.contains("。。"))
    }

    @Test func volatilePreview_alsoCollapsesDuplicatePunctuationAtTheJoin() async {
        let accumulator = TranscriptAccumulator()
        _ = await accumulator.applyFinal("你好，我们现在来再试一下语音输入的一个灵敏度怎么样？")

        // A volatile (interim) result that re-includes the same boundary mark must not double it
        // in the live preview either.
        let combined = await accumulator.applyVolatile("？Is cloud doing this")
        #expect(combined == "你好，我们现在来再试一下语音输入的一个灵敏度怎么样？Is cloud doing this")
        #expect(!combined.contains("？？"))
    }

    @Test func repeatedIdenticalMarksAcrossMultipleSegments_collapseToOne() async {
        let accumulator = TranscriptAccumulator()
        _ = await accumulator.applyFinal("Wait")
        _ = await accumulator.applyFinal("?")
        _ = await accumulator.applyFinal("?")
        let combined = await accumulator.applyFinal("?")
        #expect(combined == "Wait?")
    }

    @Test func differentMarksAtAJoin_areNotCollapsed() async {
        // A join where the two marks differ (not a duplicate) must be left alone — only exact
        // repeats of the same character are collapsed.
        let accumulator = TranscriptAccumulator()
        _ = await accumulator.applyFinal("Really")
        let combined = await accumulator.applyFinal("?!")
        #expect(combined == "Really?!")
    }

    @Test func punctuationMixWithinASingleSegment_isNeverTouched() async {
        // "?!" written by the recognizer within ONE segment (not at a join boundary) must pass
        // through completely unmodified — the fix only ever trims from the *start* of an
        // incoming segment against the *end* of what's already accumulated, never mid-string.
        let accumulator = TranscriptAccumulator()
        let combined = await accumulator.applyFinal("Really?! Are you sure?!")
        #expect(combined == "Really?! Are you sure?!")
    }

    @Test func emptyAccumulatorOrEmptySegment_isANoOp() async {
        let accumulator = TranscriptAccumulator()
        let combined = await accumulator.applyFinal("")
        #expect(combined == "")

        let accumulator2 = TranscriptAccumulator()
        _ = await accumulator2.applyFinal("Hello.")
        let combined2 = await accumulator2.applyFinal("")
        #expect(combined2 == "Hello.")
    }
}
