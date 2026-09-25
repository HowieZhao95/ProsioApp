import Testing
@testable import ProsioCore

@Test func audioFormatIs16kMono() {
    #expect(AudioFormat.pcm16Mono16k.sampleRate == 16_000)
    #expect(AudioFormat.pcm16Mono16k.channelCount == 1)
}
