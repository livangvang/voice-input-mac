import AVFoundation
import Foundation

struct CaptureSignal {
    private(set) var samples = 0
    private(set) var nonzero = 0
    var hasSignal: Bool { nonzero > 0 }
    mutating func observe(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.int16ChannelData?[0] else { return }
        samples += Int(buffer.frameLength)
        for i in 0..<Int(buffer.frameLength) where data[i] != 0 { nonzero += 1 }
    }
}

// Tap callbacks and stop share the writer only under a lock. No hardware work runs in SwiftUI rendering.
final class NativeRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var writer: AVAudioFile?
    private var converter: AVAudioConverter?
    private var conversionError: String?
    private var tapInstalled = false
    private var signal = CaptureSignal()
    private(set) var url: URL?
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInput/Recordings")
    }
    func start() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = Self.directory.appendingPathComponent(UUID().uuidString + ".wav")
        // Use the hardware input directly. Voice processing produced all-zero audio on a real Mac.
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到可用的麥克風"]) }
        self.converter = converter
        writer = try AVAudioFile(forWriting: target, settings: output.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        url = target; conversionError = nil; signal = CaptureSignal()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input) { [weak self] buffer, _ in
            guard let self else { return }
            lock.lock(); defer { lock.unlock() }
            guard let writer = self.writer, let converter = self.converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: output,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / input.sampleRate) + 64)
            else { return }
            let feed = ConverterFeed(buffer)
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                return feed.next(state)
            }
            if status == .error { self.conversionError = error?.localizedDescription ?? "錄音轉換失敗"; return }
            do { if converted.frameLength > 0 { try writer.write(from: converted); self.signal.observe(converted) } }
            catch { self.conversionError = error.localizedDescription }
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); tapInstalled = false; writer = nil; throw error }
    }
    func stop() throws -> URL {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        lock.lock()
        if let writer, let converter {
            // Finish resampling the last buffered frames before closing the WAV.
            for _ in 0..<16 {
                guard let tail = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 1024) else { break }
                var error: NSError?
                let status = converter.convert(to: tail, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                if status == .error { conversionError = error?.localizedDescription ?? "錄音轉換失敗"; break }
                do { if tail.frameLength > 0 { try writer.write(from: tail); signal.observe(tail) } }
                catch { conversionError = error.localizedDescription; break }
                if status == .endOfStream || tail.frameLength == 0 { break }
            }
        }
        writer = nil; converter = nil
        let captured = signal; lock.unlock()
        VoiceDiagnostics.record(.inputSamples, count: captured.samples)
        VoiceDiagnostics.record(.inputNonzeroSamples, count: captured.nonzero)
        guard let url else { throw CocoaError(.fileReadNoSuchFile) }
        if let conversionError { throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: conversionError]) }
        guard captured.hasSignal else {
            throw NSError(domain: "VoiceInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "麥克風沒有收到聲音"])
        }
        return url
    }
    func cancel() {
        _ = try? stop()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

// AVAudioConverter may invoke its input block from a worker. The feed retains the buffer
// and serializes consumption; the enclosing converter call completes before the tap returns.
private final class ConverterFeed: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var fed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        if fed { state.pointee = .noDataNow; return nil }
        fed = true; state.pointee = .haveData; return buffer
    }
}
