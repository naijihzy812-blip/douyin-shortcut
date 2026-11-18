import XCTest
@testable import BridgeTalkCore

final class ConversationCoreTests: XCTestCase {
    func testSilenceNeverSubmits() {
        var gate = SilenceGate(threshold: -38)
        XCTAssertEqual(gate.update(elapsed: 1, power: -60), .keepRecording)
        XCTAssertEqual(gate.update(elapsed: 18, power: -60), .discard)
    }
    func testShortNoiseIsDiscarded() {
        var gate = SilenceGate(threshold: -38)
        _ = gate.update(elapsed: 0.1, power: -20)
        XCTAssertEqual(gate.update(elapsed: 18, power: -60), .discard)
    }
    func testPauseSubmitsSpeech() {
        var gate = SilenceGate(threshold: -38)
        for time in [0.1, 0.2, 0.3] { _ = gate.update(elapsed: time, power: -20) }
        XCTAssertEqual(gate.update(elapsed: 0.8, power: -60), .keepRecording)
        XCTAssertEqual(gate.update(elapsed: 1.4, power: -60), .submit)
    }
    func testLongSpeechIsBounded() {
        var gate = SilenceGate(threshold: -38)
        for time in [1.0, 2.0, 3.0] { _ = gate.update(elapsed: time, power: -20) }
        XCTAssertEqual(gate.update(elapsed: 19.1, power: -20), .submit)
    }
    func testLateSpeechGetsFullWindow() {
        var gate = SilenceGate(threshold: -38)
        XCTAssertEqual(gate.update(elapsed: 16.9, power: -60), .keepRecording)
        for time in [17.0, 17.1, 17.2] { _ = gate.update(elapsed: time, power: -20) }
        XCTAssertEqual(gate.update(elapsed: 18, power: -20), .keepRecording)
        XCTAssertEqual(gate.update(elapsed: 35, power: -20), .submit)
    }
    func testLanguagesHaveUniqueLocales() {
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.speechLocale)).count, AppLanguage.allCases.count)
        XCTAssertEqual(AppLanguage.chinese.translationCode, "zh-Hans")
        XCTAssertEqual(AppLanguage.japanese.translationCode, "ja")
    }
    func testJapaneseAndKoreanScripts() {
        XCTAssertGreaterThan(CandidateRouter.score(.init(text: "こんにちは", locale: "ja-JP", confidence: 0.9)), 0.8)
        XCTAssertGreaterThan(CandidateRouter.score(.init(text: "안녕하세요", locale: "ko-KR", confidence: 0.9)), 0.8)
    }
    func testEmptyCandidatesNeedUser() { XCTAssertNil(CandidateRouter.pick([])) }
    func testOneFailedLanguageDoesNotGuess() {
        XCTAssertNil(CandidateRouter.pick([.init(text: "hello", locale: "en-US", confidence: 0.99)]))
    }
    func testSimilarScoresNeedUser() {
        XCTAssertNil(CandidateRouter.pick([
            .init(text: "你好", locale: "zh-CN", confidence: 0.8),
            .init(text: "hello", locale: "en-US", confidence: 0.8)]))
    }
    func testZeroConfidenceNeedsUser() {
        XCTAssertNil(CandidateRouter.pick([
            .init(text: "你好", locale: "zh-CN", confidence: 0),
            .init(text: "hello", locale: "en-US", confidence: 0)]))
    }
    func testClearMarginChoosesCandidate() {
        XCTAssertEqual(CandidateRouter.pick([
            .init(text: "你好", locale: "zh-CN", confidence: 0.95),
            .init(text: "hello", locale: "en-US", confidence: 0.2)])?.locale, "zh-CN")
    }
    func testNumbersDoNotEstablishLanguage() {
        XCTAssertNil(CandidateRouter.pick([
            .init(text: "123", locale: "zh-CN", confidence: 0.99),
            .init(text: "123", locale: "en-US", confidence: 0.2)]))
    }
}
