import AVFoundation
import XCTest
@testable import VoiceInputApp

final class VoiceCaptureTests: XCTestCase {
    func testConverterUsesTheProcessedFormatRatherThanStaleHardwareFormat() throws {
        let raw = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let processed = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        var enabled = false
        let setup = CaptureInputSetup.configure(noiseReduction: true, enable: { enabled = true },
            reset: { XCTFail("should not reset a supported input") }, readFormat: { enabled ? processed : raw })
        XCTAssertTrue(setup.processed)
        XCTAssertEqual(setup.format.sampleRate, 48000)
        XCTAssertEqual(setup.format.channelCount, 1)
    }
    func testUnsupportedProcessingRestoresRawRecordingWithoutFailing() throws {
        let raw = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        var restored = false
        let setup = CaptureInputSetup.configure(noiseReduction: true,
            enable: { throw CocoaError(.featureUnsupported) }, reset: { restored = true },
            readFormat: { XCTAssertTrue(restored); return raw })
        XCTAssertFalse(setup.processed)
        XCTAssertEqual(setup.format.sampleRate, 44100)
    }
    func testTurningProcessingOffLeavesTheHardwareConfigurationAlone() throws {
        let raw = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let setup = CaptureInputSetup.configure(noiseReduction: false,
            enable: { XCTFail("must not enable") }, reset: { XCTFail("must not reset") }, readFormat: { raw })
        XCTAssertFalse(setup.processed)
        XCTAssertEqual(setup.format.channelCount, 2)
    }
}
