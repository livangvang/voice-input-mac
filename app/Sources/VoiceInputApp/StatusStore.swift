import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

enum PanelPage: Hashable { case daily, settings }

@MainActor
final class StatusStore: ObservableObject {
    static let shared = StatusStore()
    @Published private(set) var status = AppStatus()
    @Published var panelPage: PanelPage = .daily
    @Published private(set) var busy = false
    @Published var server: String
    @Published private(set) var accountName: String?
    @Published private(set) var pairCode: String?
    @Published private(set) var message = ""
    @Published private(set) var words: [String] = []
    @Published private(set) var learning: LearningCandidate?
    @Published private(set) var retryURL: URL?
    @Published private(set) var canRetryConfirmedSpeech = false
    @Published private(set) var legacyPending = LegacyMigration.needed
    @Published private(set) var updateVersion: String?
    @Published private(set) var credentialNeedsApproval = false
    @Published private(set) var credentialLoading = false
    @Published private(set) var microphoneName = "系統預設麥克風"
    @Published var doubleControl = UserDefaults.standard.object(forKey: "doubleControl") as? Bool ?? true
    @Published private(set) var shortcut = RecordingShortcut(rawValue: UserDefaults.standard.string(forKey: "recordingShortcut") ?? "") ?? .controlOptionV
    private let hotkeys = NativeHotkeys()
    private let recordingSounds = RecordingSounds()
    private var recorder: NativeRecorder?
    private var target: NativePaste.Target?
    private var island: FloatingIsland?
    private var fallbackPanel: NSWindow?
    private var localTimer: Timer?
    private var remoteTimer: Timer?
    private var pairTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var learningTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var credentialOperation = UUID()
    private let credentials = CredentialCache()
    private var started = false
    private var legacyReloadPending = false
    private var operation = UUID()
    private var inputNotice: InputNotice?
    private var noticeUntil = Date.distantPast
    var client: SparkClient { SparkClient(base: server, token: credentials.token(for: server)) }
    var ready: Bool { status.paired && status.microphoneGranted && status.nativeHotkeysRunning && status.serverReachable == true && status.whisperReady == true && !legacyPending && !legacyReloadPending }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init() {
        let legacy = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        server = UserDefaults.standard.string(forKey: "server") ?? LegacyMigration.configValue("SERVER", in: legacy) ?? "https://spark-cb4e.taild73ae6.ts.net"
        status.localThreshold = UserDefaults.standard.object(forKey: "nativeThreshold") as? Double ?? Sensitivity.local()
        if let threshold = status.localThreshold, threshold < Sensitivity.min { status.localThreshold = nil }
        if let path = UserDefaults.standard.string(forKey: "retryRecording"), FileManager.default.fileExists(atPath: path) {
            retryURL = URL(fileURLWithPath: path)
            canRetryConfirmedSpeech = UserDefaults.standard.bool(forKey: "retrySpeechConfirmation")
        }
        legacyReloadPending = UserDefaults.standard.bool(forKey: "legacyReloadPending")
    }
    func start() {
        guard !started else { return }; started = true
        VoiceDiagnostics.record(.engineStarted)
        island = FloatingIsland()
        island?.click = { [weak self] in
            guard let self else { return }
            if learning != nil { saveLearning() }
            else if status.phase == .idle, noticeUntil > Date(), let inputNotice {
                switch inputNotice {
                case .retry: retry(toCurrentField: true)
                case .copy: copyLast()
                case .noSpeech, .microphone: startRecording()
                case .notReady: showPanel(page: .settings)
                case .copied: break
                }
            } else { showPanel() }
        }
        hotkeys.isRecording = { [weak self] in self?.status.phase == .recording }
        hotkeys.action = { [weak self] action in
            Task { @MainActor in
            guard let self else { return }
            switch action {
            case "start": self.startRecording()
            case "stop": self.finishRecording()
            case "cancel": self.cancelRecording()
            case "panel": self.showPanel()
            default: self.toggleRecording()
            }
            }
        }
        refreshPermissions()
        localTimer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.renderIsland() }
        }
        remoteTimer = .scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRemote() }
        }
        refreshNow()
        loadAccountCredential()
    }
    func stop() {
        localTimer?.invalidate(); remoteTimer?.invalidate(); hotkeys.stop()
        pairTask?.cancel(); uploadTask?.cancel(); learningTask?.cancel()
        credentialTask?.cancel()
        if status.phase == .recording { recorder?.cancel() }
    }
    func showPanel(page: PanelPage = .daily) {
        panelPage = page
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Background launch may not create SwiftUI's primary scene. Keep the recovery UI reachable.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "超簡單語音輸入"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(self).preferredColorScheme(.dark))
            window.center(); fallbackPanel = window
            window.makeKeyAndOrderFront(nil)
        }
    }
    private func refreshPermissions() {
        status.accessibilityGranted = AXIsProcessTrusted()
        status.microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hotkeys.doubleControl = doubleControl
        hotkeys.shortcut = shortcut
        if status.accessibilityGranted == true && !legacyPending && !legacyReloadPending {
            status.nativeHotkeysRunning = hotkeys.start()
        } else { hotkeys.stop(); status.nativeHotkeysRunning = false }
        AppIcon.apply(status)
    }
    func requestMicrophone() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) } else { openMicrophoneSettings() }
            refreshPermissions()
        }
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func openAccessibilitySettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
    func openMicrophoneSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    func setServer(_ value: String) {
        guard status.phase == .idle else { message = "請先結束這次錄音與辨識"; return }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean), url.scheme == "https", url.host != nil, url.user == nil, url.query == nil, url.fragment == nil else { message = "請輸入 HTTPS Spark 網址"; return }
        pairTask?.cancel(); pairCode = nil; server = clean; UserDefaults.standard.set(clean, forKey: "server")
        accountName = nil; status.paired = false; status.history = []; words = []
        status.serverReachable = nil; status.whisperReady = nil; refreshNow()
        loadAccountCredential()
    }
    private func loadAccountCredential(allowInteraction: Bool = false) {
        credentialTask?.cancel()
        let origin = server
        let operation = UUID(); credentialOperation = operation
        credentialNeedsApproval = false; credentialLoading = true
        credentialTask = Task {
            defer { if operation == credentialOperation { credentialLoading = false } }
            do {
                try await credentials.load(server: origin, allowInteraction: allowInteraction)
                try Task.checkCancellation()
                guard origin == server, operation == credentialOperation else { return }
                credentialNeedsApproval = false
                await refreshRemote()
            } catch is CancellationError { }
            catch {
                guard origin == server, operation == credentialOperation, !Task.isCancelled else { return }
                credentialNeedsApproval = true
                message = error.localizedDescription
            }
        }
    }
    func restoreAccountAccess() { loadAccountCredential(allowInteraction: true) }
    func configureHotkey(_ enabled: Bool) { doubleControl = enabled; UserDefaults.standard.set(enabled, forKey: "doubleControl") }
    func configureShortcut(_ value: RecordingShortcut) { shortcut = value; hotkeys.shortcut = value; UserDefaults.standard.set(value.rawValue, forKey: "recordingShortcut") }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; objectWillChange.send() }
        catch { message = "登入啟動設定失敗：\(error.localizedDescription)" }
    }
    func migrateLegacy() {
        guard status.phase == .idle else { message = "請先結束錄音"; return }
        Task {
            do {
                let changed = try LegacyMigration.backupAndDisable()
                legacyPending = false
                if changed && SystemProbe.hammerspoonRunning() {
                    legacyReloadPending = true; UserDefaults.standard.set(true, forKey: "legacyReloadPending")
                    if SystemProbe.hsPath != nil {
                        await SystemProbe.reloadHammerspoon()
                        try? await Task.sleep(for: .seconds(2))
                        let unloaded = await SystemProbe.run(SystemProbe.hsPath!, ["-t", "2", "-c", #"return tostring(package.loaded["voice-input-float"] == nil and package.loaded["voice-input-menubar"] == nil)"#], timeout: 4)
                        if unloaded?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                            legacyReloadPending = false; UserDefaults.standard.set(false, forKey: "legacyReloadPending")
                        } else { message = "無法確認舊模組已停止，請在 Hammerspoon Reload Config 後確認完成。" }
                    } else { message = "已備份並停用舊版載入。請在 Hammerspoon 按 Reload Config，再按確認完成。" }
                }
                refreshPermissions()
            } catch { message = "遷移失敗，舊設定仍保留：\(error.localizedDescription)" }
        }
    }
    func confirmLegacyReload() { legacyReloadPending = false; UserDefaults.standard.set(false, forKey: "legacyReloadPending"); refreshPermissions() }
    var needsLegacyReload: Bool { legacyReloadPending }
    func linkAccount() {
        if let pairCode { open(server + "/account#pair=" + pairCode) }
        else { pair() }
    }
    func pair() {
        guard status.phase == .idle else { message = "請先結束這次錄音與辨識"; return }
        pairTask?.cancel()
        pairTask = Task {
            do {
                let origin = SparkClient(base: server)
                let pairing = try await origin.startPairing(name: Host.current().localizedName ?? "我的 Mac")
                try Task.checkCancellation()
                pairCode = pairing.userCode
                message = "請在網頁確認帳號與電腦，按「允許連結」後會自動完成。"
                open(pairing.verificationURL)
                for _ in 0..<200 {
                    try await Task.sleep(for: .seconds(3))
                    let result = try await origin.request("/api/pair/exchange", json: ["device_code": pairing.deviceCode])
                    if let token = result["token"] as? String {
                        try Task.checkCancellation()
                        try await credentials.save(token, server: origin.base)
                        try Task.checkCancellation()
                        guard origin.base == server else { return }
                        credentialNeedsApproval = false
                        pairCode = nil; message = "已配對這台 Mac"; await refreshRemote(); return
                    }
                }
                pairCode = nil; message = "連結已過期，請重新按「連結我的帳號」。"
            } catch is CancellationError { }
            catch { if !Task.isCancelled { pairCode = nil; message = error.localizedDescription } }
        }
    }
    func openWebVersion() {
        Task {
            do { let response = try await client.request("/api/session/start", json: [:]); if let path = response["path"] as? String, path.hasPrefix("/account#login=") { open(server + path) } }
            catch { message = error.localizedDescription; open(server + "/account") }
        }
    }
    func openDownload() { open(server + "/download") }
    func wakeServer() {
        Task { do { _ = try await client.request("/api/service/wake", json: [:]); await refreshRemote() } catch { message = error.localizedDescription } }
    }
    func refreshNow() { refreshPermissions(); Task { await refreshRemote() } }
    private func refreshRemote() async {
        let origin = server
        // Network readiness does not wait for Keychain approval or account access.
        let health = await SparkClient(base: origin).health()
        guard origin == server else { return }
        microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "系統預設麥克風"
        status.serverReachable = health != nil; status.whisperReady = health?.whisperReady; status.threshold = health?.threshold
        status.usesVoiceDetection = health?.speechGate == "vad"; status.serverCheckedAt = Date()
        let c = client
        if c.token != nil && health != nil {
            do {
                let me = try await c.request("/api/me")
                guard c.base == server else { return }
                accountName = me["name"] as? String; status.paired = accountName != nil
                let history = await c.history()
                guard c.base == server else { return }
                status.history = history
                await refreshVocab()
            } catch SparkClient.Failure.unauthorized {
                guard c.base == server, c.token == credentials.token(for: server) else { return }
                credentials.clear(server: c.base); accountName = nil; status.paired = false; status.history = []; words = []; message = "配對已失效，請重新配對"
            }
            catch { if c.base == server { message = error.localizedDescription } }
        } else if c.token == nil { status.paired = false; accountName = nil; status.history = []; words = [] }
        if let result = try? await c.request("/api/releases"), let entries = result["items"] as? [[String: Any]], let mac = entries.first(where: { $0["platform"] as? String == "mac" }) {
            guard c.base == server else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if let version = mac["version"] as? String, version.compare(current, options: .numeric) == .orderedDescending { updateVersion = version }
        }
        AppIcon.apply(status)
    }
    func toggleRecording() { status.phase == .recording ? finishRecording() : startRecording() }
    func startRecording() {
        guard ready else { message = "請先完成配對、權限與伺服器檢查"; notify(.notReady); return }
        guard status.phase == .idle, !busy else { return }
        inputNotice = nil
        learningTask?.cancel(); learning = nil
        target = NativePaste.capture()
        let recorder = NativeRecorder()
        do {
            try recorder.start(); self.recorder = recorder; status.phase = .recording; status.recordingSince = Date(); message = ""
            VoiceDiagnostics.record(.recordingStarted)
            recordingSounds.play(.start); renderIsland()
            let session = UUID(); operation = session
            Task { try? await Task.sleep(for: .seconds(180)); if operation == session && status.phase == .recording { finishRecording() } }
        } catch { recorder.cancel(); message = error.localizedDescription; VoiceDiagnostics.record(.recordingFailed); notify(.microphone) }
    }
    func finishRecording() {
        guard status.phase == .recording, let recorder else { return }
        defer { recordingSounds.play(.finish) }
        do { let url = try recorder.stop(); self.recorder = nil; VoiceDiagnostics.record(.recordingStopped); upload(url, target: target) }
        catch {
            if let url = recorder.url {
                retainForRetry(url)
            }
            self.recorder = nil; status.phase = .idle; message = error.localizedDescription; renderIsland()
            VoiceDiagnostics.record(.recordingFailed); notify(.microphone)
        }
    }
    func cancelRecording() {
        guard status.phase == .recording else { return }
        operation = UUID(); recorder?.cancel(); recorder = nil; status.phase = .idle; status.recordingSince = nil
        message = "已取消，沒有送出辨識"; renderIsland()
    }
    func retry(speechConfirmed: Bool = false, toCurrentField: Bool = false) {
        guard !busy, !speechConfirmed || canRetryConfirmedSpeech, let url = retryURL else { return }
        upload(url, target: toCurrentField ? NativePaste.capture() : nil, speechConfirmed: speechConfirmed)
    }
    func recordAgain() { guard !busy, ready else { return }; startRecording() }
    func openSavedRecordings() {
        do {
            try FileManager.default.createDirectory(at: RecordingArchive.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(RecordingArchive.directory)
        } catch { message = error.localizedDescription }
    }
    private func retainForRetry(_ url: URL) {
        if let previous = retryURL {
            do { try RecordingArchive.preserve(previous, replacingWith: url) }
            catch { VoiceDiagnostics.record(.recordingArchiveFailed) }
        }
        retryURL = url; UserDefaults.standard.set(url.path, forKey: "retryRecording")
    }
    func discardRetry() {
        guard !busy else { return }
        clearRetry()
        message = "已清除上次錄音"
    }
    private func clearRetry() {
        if let url = retryURL { try? FileManager.default.removeItem(at: url) }
        retryURL = nil; canRetryConfirmedSpeech = false
        UserDefaults.standard.removeObject(forKey: "retryRecording")
        UserDefaults.standard.removeObject(forKey: "retrySpeechConfirmation")
    }
    private func upload(_ url: URL, target: NativePaste.Target?, speechConfirmed: Bool = false) {
        inputNotice = nil
        status.phase = .transcribing; status.recordingSince = nil; busy = true; renderIsland()
        retainForRetry(url)
        let c = client
        uploadTask = Task {
            defer { busy = false; status.phase = .idle; renderIsland() }
            do {
                let data = try Data(contentsOf: url)
                let result = try await c.request("/api/transcribe", audio: data, threshold: status.localThreshold, speechConfirmed: speechConfirmed)
                let outcome = try TranscriptionOutcome(result)
                status.last = LastResult(kind: outcome.succeeded ? .ok : .skipped, text: outcome.text, seconds: result["seconds"] as? Double, reason: outcome.reason, gate: outcome.gate, at: Date())
                if let text = outcome.text {
                    VoiceDiagnostics.record(.textReady, count: text.count, confirmed: speechConfirmed)
                    if let target, NativePaste.paste(text, to: target) {
                        message = "已輸入"; monitorEdits(target, inserted: text)
                        VoiceDiagnostics.record(.pasteSent)
                    } else {
                        message = target == nil ? "重試完成，請按「複製結果」貼到需要的地方" : "目標已改變或無法確認；結果已保留，請按複製"
                        VoiceDiagnostics.record(.pasteHeld)
                        notify(.copy)
                    }
                    clearRetry()
                    // A slow history refresh must not keep the next recording blocked.
                    Task {
                        let history = await c.history()
                        guard c.base == server, c.token == credentials.token(for: server) else { return }
                        status.history = history
                    }
                } else {
                    canRetryConfirmedSpeech = outcome.canRetryConfirmedSpeech
                    UserDefaults.standard.set(canRetryConfirmedSpeech, forKey: "retrySpeechConfirmation")
                    message = "\(outcome.reason ?? "沒有辨識到內容")。錄音已保留，可以直接再說一次。"
                    VoiceDiagnostics.record(outcome.gate?.passed == false ? .gateRejected : .recognitionSkipped, confirmed: speechConfirmed)
                    notify(.noSpeech)
                }
            } catch {
                status.last = LastResult(kind: .error, text: nil, seconds: nil, reason: error.localizedDescription, gate: nil, at: Date())
                message = "辨識未完成，錄音已保留，可重試：\(error.localizedDescription)"
                VoiceDiagnostics.record(.uploadFailed, confirmed: speechConfirmed); notify(.retry)
            }
        }
    }
    func copyLast() { if let text = status.last?.text { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "已複製"; notify(.copied) } }
    func setThreshold(_ value: Double?) { status.localThreshold = value; if let value { UserDefaults.standard.set(value, forKey: "nativeThreshold") } else { UserDefaults.standard.set(-1.0, forKey: "nativeThreshold"); status.localThreshold = nil } }
    func refreshVocab() async {
        let c = client
        if let d = try? await c.request("/api/vocab"), c.base == server, c.token == credentials.token(for: server) {
            words = d["words"] as? [String] ?? []
        }
    }
    func addWord(_ word: String) { Task { do { _ = try await client.request("/api/vocab", json: ["word": word]); await refreshVocab() } catch { message = error.localizedDescription } } }
    func removeWord(_ word: String) { Task { do { _ = try await client.request("/api/vocab/remove", json: ["word": word]); await refreshVocab() } catch { message = error.localizedDescription } } }
    func learn(original: String, edited: String) { guard let candidate = LearningCandidate.diff(original, edited) else { message = "請選一個短詞的修改，避免整句改寫"; return }; learning = candidate; renderIsland() }
    func dismissLearning() { learning = nil; renderIsland() }
    func saveLearning() {
        guard let candidate = learning else { return }; learning = nil
        Task { do { _ = try await client.request("/api/corrections", json: ["bad":candidate.bad, "good":candidate.good]); message = "已學習：\(candidate.bad) → \(candidate.good)"; await refreshVocab() } catch { message = error.localizedDescription }; renderIsland() }
    }
    private func monitorEdits(_ target: NativePaste.Target, inserted: String) {
        learningTask?.cancel()
        learningTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard let field = target.field, NativePaste.sameFocus(target), let baseline = NativePaste.value(field), let range = baseline.range(of: inserted, options: .backwards) else { return }
            let prefix = String(baseline[..<range.lowerBound]), suffix = String(baseline[range.upperBound...])
            var previous = baseline, changedAt = Date(), offered = false
            for _ in 0..<128 {
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard NativePaste.sameFocus(target), let text = NativePaste.value(field) else { return }
                if text != previous { previous = text; changedAt = Date(); offered = false }
                if !offered, text != baseline, Date().timeIntervalSince(changedAt) >= 3,
                   text.hasPrefix(prefix), text.hasSuffix(suffix), text.count >= prefix.count + suffix.count {
                    let edited = String(text.dropFirst(prefix.count).dropLast(suffix.count))
                    if let candidate = LearningCandidate.diff(inserted, edited) {
                        learning = candidate; offered = true; renderIsland()
                        try? await Task.sleep(for: .seconds(5))
                        if learning == candidate { learning = nil; renderIsland() }
                    }
                }
            }
        }
    }
    private func renderIsland() {
        let text: String? = learning.map { "\($0.bad) → \($0.good) · 點一下學起來" }
            ?? (status.phase == .idle && noticeUntil > Date() ? inputNotice?.text : nil)
        island?.update(phase: status.phase, since: status.recordingSince, message: text, asking: learning != nil)
        AppIcon.apply(status)
    }
    private func notify(_ notice: InputNotice) {
        inputNotice = notice; noticeUntil = Date().addingTimeInterval(8); renderIsland()
    }
}
