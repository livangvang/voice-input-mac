import Foundation
import Security
import LocalAuthentication
import CoreGraphics
import OSLog

enum VoiceDiagnostics {
    private static let logger = Logger(subsystem: "tw.shadowperformance.voiceinput", category: "input")
    enum Event: String { case engineStarted, inputSamples, inputNonzeroSamples, recordingArchiveFailed, startCuePlayed, finishCuePlayed, cueUnavailable, recordingStarted, recordingStopped, recordingFailed, gateRejected, recognitionSkipped, textReady, pasteSent, pasteHeld, uploadFailed }
    static func record(_ event: Event, count: Int = 0, confirmed: Bool = false) {
        // Only fixed event names and counts: no audio, transcript, window title, account or credential.
        logger.notice("event=\(event.rawValue, privacy: .public) count=\(count, privacy: .public) confirmed=\(confirmed, privacy: .public)")
    }
}

enum InputNotice {
    case noSpeech, retry, copy, notReady, microphone, copied
    var text: String {
        switch self {
        case .noSpeech: "這句沒辨識到，直接再說一次"
        case .retry: "辨識未完成，點一下重試"
        case .copy: "文字已保留，點一下複製"
        case .notReady: "尚未就緒，點一下查看原因"
        case .microphone: "沒收到聲音，直接再說一次"
        case .copied: "已複製"
        }
    }
}

enum RecordingArchive {
    static var directory: URL { NativeRecorder.directory.appendingPathComponent("Saved", isDirectory: true) }
    static func preserve(_ url: URL, replacingWith next: URL, in directory: URL = directory) throws {
        guard url != next, url.deletingLastPathComponent() != directory,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent))
    }
}

struct TranscriptionOutcome {
    let text: String?
    let reason: String?
    let gate: Gate?
    var succeeded: Bool { text != nil }
    var canRetryConfirmedSpeech: Bool {
        guard !succeeded, let gate, let p95 = gate.p95, let minimum = gate.needP95,
              let ratio = gate.ratio, let required = gate.needRatio else { return false }
        return p95 >= minimum && ratio >= 2.0 && ratio < required
    }
    init(_ response: [String: Any]) throws {
        if let error = response["error"] as? String { throw SparkClient.Failure.message(error) }
        gate = Gate(response["gate"] as? String)
        if response["skipped"] as? Bool == true {
            text = nil; reason = response["reason"] as? String ?? "沒有辨識到內容"
        } else if let value = response["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = value; reason = nil
        } else { throw SparkClient.Failure.message("伺服器沒有回傳辨識內容") }
    }
}

enum RecordingShortcut: String, CaseIterable {
    case controlOptionV, controlOptionSpace, controlShiftSpace
    var label: String {
        switch self {
        case .controlOptionV: "Ctrl + Option + V"
        case .controlOptionSpace: "Ctrl + Option + 空白鍵"
        case .controlShiftSpace: "Ctrl + Shift + 空白鍵"
        }
    }
    func matches(key: Int64, modifiers: CGEventFlags) -> Bool {
        let required: CGEventFlags = self == .controlShiftSpace ? [.maskControl, .maskShift] : [.maskControl, .maskAlternate]
        return key == (self == .controlOptionV ? 9 : 49)
            && modifiers.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]) == required
    }
}

struct ControlGesture {
    enum Action: Equatable { case start, stop }
    private var pressed: TimeInterval?
    private var lastRelease: TimeInterval?
    private var dirty = false
    private var fired = -Double.infinity
    mutating func down(at time: TimeInterval) -> Action? {
        if pressed == nil { pressed = time; dirty = false }
        return nil
    }
    mutating func otherKey() { dirty = true; lastRelease = nil }
    mutating func up(at time: TimeInterval, recording: Bool) -> Action? {
        defer { pressed = nil }
        guard let pressed, time - pressed <= 0.4, !dirty else { lastRelease = nil; return nil }
        if recording {
            guard time - fired > 0.4 else { return nil }
            fired = time; lastRelease = nil; return .stop
        }
        guard time - fired >= 1 else { lastRelease = nil; return nil }
        if let lastRelease, time - lastRelease <= 0.4 {
            fired = time; self.lastRelease = nil; return .start
        }
        lastRelease = time
        return nil
    }
}

enum LegacyMigration {
    static let modules = ["voice-input-menubar", "voice-input-chime", "voice-input-run-fix",
                          "voice-input-panel-hotkey", "voice-input-float", "voice-input-autolearn"]
    static func disabledLoaders(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            let recognized = modules.contains { t == "require(\"\($0)\")" || t == "require('\($0)')" }
                || t == #"dofile(os.getenv("HOME") .. "/.hammerspoon/voice-input.lua")"#
            return recognized ? "-- VoiceInput native migration: " + line : line
        }.joined(separator: "\n")
    }
    static func configValue(_ key: String, in source: String) -> String? {
        for line in source.components(separatedBy: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key + "=") else { continue }
            let value = t.dropFirst(key.count + 1).split(separator: "#", maxSplits: 1).first ?? ""
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        }
        return nil
    }
    static func backupAndDisable() throws -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/init.lua")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let original = try String(contentsOf: path, encoding: .utf8)
        let updated = disabledLoaders(original)
        guard updated != original else { return false }
        let backup = path.appendingPathExtension("voice-input-\(Int(Date().timeIntervalSince1970)).bak")
        try FileManager.default.copyItem(at: path, to: backup)
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return true
    }
    static var needed: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/init.lua")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else { return false }
        return disabledLoaders(source) != source
    }
}

struct LearningCandidate: Equatable {
    let bad: String
    let good: String
    static func diff(_ original: String, _ edited: String) -> Self? {
        let a = Array(original), b = Array(edited)
        guard a != b, !a.isEmpty, !b.isEmpty else { return nil }
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        guard prefix + suffix > 0 || a.count <= 4 else { return nil }
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        while prefix > 0, prefix < a.count, prefix < b.count,
              word(a[prefix - 1]), word(a[prefix]) || word(b[prefix]) { prefix -= 1 }
        while suffix > 0, a.count - suffix > 0, b.count - suffix > 0,
              word(a[a.count - suffix]), word(a[a.count - suffix - 1]) || word(b[b.count - suffix - 1]) { suffix -= 1 }
        var bad = String(a[prefix..<(a.count - suffix)]), good = String(b[prefix..<(b.count - suffix)])
        while bad.isEmpty || good.isEmpty || (!bad.allSatisfy(\.isASCII) && bad.count < 2) {
            if suffix > 0 { suffix -= 1 } else if prefix > 0 { prefix -= 1 } else { return nil }
            bad = String(a[prefix..<(a.count - suffix)]); good = String(b[prefix..<(b.count - suffix)])
        }
        let ascii = (bad + good).allSatisfy(\.isASCII)
        guard bad.count <= (ascii ? 50 : 4), good.count <= (ascii ? 50 : 4),
              ascii || bad.count == good.count,
              !(bad + good).contains(where: \.isNewline),
              bad == bad.trimmingCharacters(in: .whitespaces),
              good == good.trimmingCharacters(in: .whitespaces) else { return nil }
        return Self(bad: bad, good: good)
    }
}

protocol CredentialStorage: Sendable {
    func load(server: String, allowInteraction: Bool) async throws -> String?
    func save(_ token: String, server: String) async throws
}

actor DeviceCredential: CredentialStorage {
    static let shared = DeviceCredential()
    enum Failure: LocalizedError {
        case approvalRequired, unavailable
        var errorDescription: String? {
            switch self {
            case .approvalRequired: "帳號憑證需要你的確認，請按「恢復帳號存取」。"
            case .unavailable: "無法讀取 Keychain 帳號憑證，請解鎖 Mac 後重新嘗試。"
            }
        }
    }
    private func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tw.shadowperformance.voiceinput.device",
         kSecAttrAccount as String: server]
    }
    func load(server: String, allowInteraction: Bool) throws -> String? {
        var q = query(server)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        q[kSecUseAuthenticationContext as String] = context
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        if result == errSecInteractionNotAllowed || result == errSecAuthFailed { throw Failure.approvalRequired }
        guard result == errSecSuccess, let data = item as? Data else { throw Failure.unavailable }
        return String(data: data, encoding: .utf8)
    }
    func save(_ token: String, server: String) throws {
        var q = query(server)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            q.merge(attributes) { _, new in new }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        } else if result != errSecSuccess { throw CocoaError(.fileWriteNoPermission) }
    }
}

@MainActor
final class CredentialCache {
    private let storage: any CredentialStorage
    private var tokens: [String: String] = [:]
    init(storage: any CredentialStorage = DeviceCredential.shared) { self.storage = storage }
    func token(for server: String) -> String? { tokens[server] }
    func load(server: String, allowInteraction: Bool) async throws {
        let token = try await storage.load(server: server, allowInteraction: allowInteraction)
        try Task.checkCancellation()
        tokens[server] = token
    }
    func save(_ token: String, server: String) async throws {
        try await storage.save(token, server: server)
        tokens[server] = token
    }
    func clear(server: String) { tokens[server] = nil }
}
