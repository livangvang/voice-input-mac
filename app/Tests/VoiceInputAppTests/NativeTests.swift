import XCTest
@testable import VoiceInputApp

final class NativeTests: XCTestCase {
    func testShortcutRequiresExactModifiers() {
        XCTAssertTrue(RecordingShortcut.controlOptionV.matches(key: 9, modifiers: [.maskControl, .maskAlternate]))
        XCTAssertFalse(RecordingShortcut.controlOptionV.matches(key: 9, modifiers: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertTrue(RecordingShortcut.controlShiftSpace.matches(key: 49, modifiers: [.maskControl, .maskShift, .maskAlphaShift]))
        XCTAssertFalse(RecordingShortcut.controlShiftSpace.matches(key: 9, modifiers: [.maskControl, .maskShift]))
    }
    func testDoubleControlAndDirtyChord() {
        var g = ControlGesture()
        XCTAssertNil(g.down(at: 1))
        XCTAssertNil(g.up(at: 1.1, recording: false))
        _ = g.down(at: 1.2)
        XCTAssertEqual(g.up(at: 1.3, recording: false), .start)
        _ = g.down(at: 3); g.otherKey()
        XCTAssertNil(g.up(at: 3.1, recording: false))
        _ = g.down(at: 3.2)
        XCTAssertNil(g.up(at: 3.3, recording: false))
    }
    func testLongControlAndStop() {
        var g = ControlGesture()
        _ = g.down(at: 1)
        XCTAssertNil(g.up(at: 2, recording: false))
        _ = g.down(at: 3)
        XCTAssertEqual(g.up(at: 3.1, recording: true), .stop)
    }
    func testLegacyMigrationPreservesOtherModules() {
        let source = "require(\"my-other-module\")\nrequire(\"voice-input-float\")\ndofile(os.getenv(\"HOME\") .. \"/.hammerspoon/voice-input.lua\")\n-- custom\n"
        let migrated = LegacyMigration.disabledLoaders(source)
        XCTAssertTrue(migrated.contains("require(\"my-other-module\")"))
        XCTAssertFalse(migrated.split(separator: "\n").contains { $0.hasPrefix("require(\"voice-input-") })
        XCTAssertEqual(LegacyMigration.disabledLoaders(migrated), migrated)
        XCTAssertTrue(migrated.contains("-- custom"))
    }
    func testConfigStripsInlineComment() {
        XCTAssertEqual(LegacyMigration.configValue("SERVER", in: "SERVER=\"https://example.ts.net\" # note"), "https://example.ts.net")
    }
    func testLearningRequiresSmallReplacementAndExplicitConfirmation() {
        XCTAssertEqual(LearningCandidate.diff("今天找少庭開會", "今天找紹庭開會")?.good, "紹庭")
        XCTAssertNil(LearningCandidate.diff("我同意這個提案", "全部重寫成很長的句子吧"))
        XCTAssertNil(LearningCandidate.diff("今天開會", "今天開會"))
    }
}
