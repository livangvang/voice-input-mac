import XCTest
@testable import VoiceInputApp

final class DirectInsertTests: XCTestCase {
    func testInsertedOnlyWhenTextAppearsAndFieldChanged() {
        XCTAssertTrue(DirectInsert.looksInserted(before: "你好", after: "你好，今天開會", text: "，今天開會"))
        XCTAssertFalse(DirectInsert.looksInserted(before: "你好", after: "你好", text: "今天"))        // 回報成功但沒寫進去
        XCTAssertFalse(DirectInsert.looksInserted(before: "你好", after: nil, text: "今天"))           // 讀不回來＝不確定，當失敗
        XCTAssertFalse(DirectInsert.looksInserted(before: "今天", after: "今天", text: "今天"))        // 原本就有同一段字
    }

    @MainActor
    func testElectronAndChromiumSkipDirectInsert() {
        XCTAssertFalse(DirectInsert.supported("com.microsoft.VSCode"))
        XCTAssertFalse(DirectInsert.supported("com.google.Chrome"))
        XCTAssertFalse(DirectInsert.supported(nil))
        XCTAssertTrue(DirectInsert.supported("com.apple.Notes.\(UUID().uuidString)"))
    }
}
