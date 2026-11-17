import XCTest
@testable import VoiceInputApp

final class TranscriptionOutcomeTests: XCTestCase {
    func testSkippedSpeechMustRemainRetryableEvenWithHTTP200() throws {
        let result = try TranscriptionOutcome(["skipped": true, "reason": "只聽到環境噪音",
            "gate": "gate: p95=1725 median=1178 floor=755 ratio=2.29 (需 p95>=418 且 ratio>=2.50)"])
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.canRetryConfirmedSpeech)
    }
    func testQuietOrUniformAudioCannotUseRelaxedRetry() throws {
        for gate in ["gate: p95=100 median=90 floor=40 ratio=2.50 (需 p95>=418 且 ratio>=2.50)",
                     "gate: p95=1800 median=1800 floor=1800 ratio=1.00 (需 p95>=418 且 ratio>=2.50)"] {
            let result = try TranscriptionOutcome(["skipped": true, "reason": "沒有語音", "gate": gate])
            XCTAssertFalse(result.canRetryConfirmedSpeech)
            XCTAssertFalse(result.succeeded)
        }
    }
    func testOnlyActualTextCompletesTheRecording() throws {
        let result = try TranscriptionOutcome(["text": "測試成功", "seconds": 1.2])
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.canRetryConfirmedSpeech)
        XCTAssertEqual(result.text, "測試成功")
        for response in [[String: Any](), ["error": "音訊格式錯誤"], ["text": ""]] {
            XCTAssertThrowsError(try TranscriptionOutcome(response))
        }
    }
}
