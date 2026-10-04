import AVFoundation
import XCTest
@testable import VoiceInputApp

final class VoiceCaptureTests: XCTestCase {
    private func buffer(_ values: [Int16]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for (i, value) in values.enumerated() { samples[i] = value }
        return buffer
    }
    func testARecordingFileWithOnlyZeroSamplesIsNotValidCapture() throws {
        var signal = CaptureSignal()
        signal.observe(try buffer(Array(repeating: 0, count: 16000)))
        XCTAssertEqual(signal.samples, 16000)
        XCTAssertEqual(signal.nonzero, 0)
        XCTAssertFalse(signal.hasSignal)
    }
    func testQuietSignalIsNotRejectedByAnArbitraryLoudnessThreshold() throws {
        var signal = CaptureSignal()
        signal.observe(try buffer([0, 1, -1, 0]))
        XCTAssertEqual(signal.samples, 4)
        XCTAssertEqual(signal.nonzero, 2)
        XCTAssertTrue(signal.hasSignal)
    }
    func testInitialSilenceDoesNotInvalidateLaterInput() throws {
        var signal = CaptureSignal()
        signal.observe(try buffer([0, 0, 0]))
        signal.observe(try buffer([0, 200, -200]))
        signal.observe(try buffer([0, 0, 0]))
        XCTAssertEqual(signal.samples, 9)
        XCTAssertTrue(signal.hasSignal)
    }
    func testNoFramesNeverCountsAsReceivedSound() {
        XCTAssertFalse(CaptureSignal().hasSignal)
    }
}

final class RecordingArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testRecordingAgainPreservesThePreviousClipAndLeavesNewClipIntact() throws {
        let previous = root.appendingPathComponent("previous.wav"), next = root.appendingPathComponent("next.wav")
        let saved = root.appendingPathComponent("Saved")
        try Data([1, 2, 3]).write(to: previous); try Data([4, 5, 6]).write(to: next)
        try RecordingArchive.preserve(previous, replacingWith: next, in: saved)
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("previous.wav")), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: next), Data([4, 5, 6]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testRetryingTheSameClipDoesNotMoveOrDiscardIt() throws {
        let previous = root.appendingPathComponent("previous.wav")
        try Data([1, 2, 3]).write(to: previous)
        try RecordingArchive.preserve(previous, replacingWith: previous, in: root.appendingPathComponent("Saved"))
        XCTAssertEqual(try Data(contentsOf: previous), Data([1, 2, 3]))
    }
}
