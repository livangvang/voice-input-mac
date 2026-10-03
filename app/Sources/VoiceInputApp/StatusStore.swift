import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var status = AppStatus()
    @Published private(set) var busy = false
    @Published var server: String
    @Published private(set) var accountName: String?
    @Published private(set) var pairCode: String?
    @Published private(set) var message = ""
    @Published private(set) var words: [String] = []
    @Published private(set) var learning: LearningCandidate?
    @Published private(set) var retryURL: URL?
    @Published private(set) var legacyPending = LegacyMigration.needed
    @Published private(set) var updateVersion: String?
    @Published var doubleControl = UserDefaults.standard.object(forKey: "doubleControl") as? Bool ?? true
    private let hotkeys = NativeHotkeys()
    private var recorder: NativeRecorder?
    private var target: NativePaste.Target?
    private var island: FloatingIsland?
    private var localTimer: Timer?
    private var remoteTimer: Timer?
    private var pairTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var learningTask: Task<Void, Never>?
    private var started = false
    private var legacyReloadPending = false
    private var operation = UUID()
    var client: SparkClient { SparkClient(base: server, token: DeviceCredential.load(server: server)) }
    var ready: Bool { status.paired && status.microphoneGranted && status.nativeHotkeysRunning && status.serverReachable == true && status.whisperReady == true && !legacyPending && !legacyReloadPending }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    init() {
        let legacy = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        server = UserDefaults.standard.string(forKey: "server") ?? LegacyMigration.configValue("SERVER", in: legacy) ?? "https://spark-cb4e.taild73ae6.ts.net"
        status.localThreshold = UserDefaults.standard.object(forKey: "nativeThreshold") as? Double ?? Sensitivity.local()
        if let threshold = status.localThreshold, threshold < Sensitivity.min { status.localThreshold = nil }
        if let path = UserDefaults.standard.string(forKey: "retryRecording"), FileManager.default.fileExists(atPath: path) { retryURL = URL(fileURLWithPath: path) }
        legacyReloadPending = UserDefaults.standard.bool(forKey: "legacyReloadPending")
    }
    func start() {
        guard !started else { return }; started = true
        island = FloatingIsland()
        island?.click = { [weak self] in
            guard let self else { return }
            if learning != nil { saveLearning() } else { showPanel() }
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
    }
    func stop() {
        localTimer?.invalidate(); remoteTimer?.invalidate(); hotkeys.stop()
        pairTask?.cancel(); uploadTask?.cancel(); learningTask?.cancel()
        if status.phase == .recording { recorder?.cancel() }
    }
    func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
    private func refreshPermissions() {
        status.accessibilityGranted = AXIsProcessTrusted()
        status.microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hotkeys.doubleControl = doubleControl
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
    }
    func configureHotkey(_ enabled: Bool) { doubleControl = enabled; UserDefaults.standard.set(enabled, forKey: "doubleControl") }
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
    func pair() {
        guard status.phase == .idle else { message = "請先結束這次錄音與辨識"; return }
        pairTask?.cancel()
        pairTask = Task {
            do {
                let origin = SparkClient(base: server)
                let p = try await origin.request("/api/pair/start", json: ["name": Host.current().localizedName ?? "我的 Mac", "platform": "mac"])
                guard let secret = p["device_code"] as? String, let code = p["user_code"] as? String else { return }
                pairCode = code; open(server + "/account")
                for _ in 0..<200 {
                    try await Task.sleep(for: .seconds(3))
                    let result = try await origin.request("/api/pair/exchange", json: ["device_code": secret])
                    if let token = result["token"] as? String {
                        try Task.checkCancellation()
                        try DeviceCredential.save(token, server: origin.base)
                        pairCode = nil; message = "已配對這台 Mac"; await refreshRemote(); return
                    }
                }
                pairCode = nil; message = "配對已過期，請重新產生配對碼"
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
        let c = client
        let health = await c.health()
        guard c.base == server else { return }
        status.serverReachable = health != nil; status.whisperReady = health?.whisperReady; status.threshold = health?.threshold; status.serverCheckedAt = Date()
        if c.token != nil && health != nil {
            do {
                let me = try await c.request("/api/me")
                guard c.base == server else { return }
                accountName = me["name"] as? String; status.paired = accountName != nil
                let history = await c.history()
                guard c.base == server else { return }
                status.history = history
                await refreshVocab()
            } catch SparkClient.Failure.unauthorized { accountName = nil; status.paired = false; status.history = []; words = []; message = "配對已失效，請重新配對" }
            catch { message = error.localizedDescription }
        } else if c.token == nil { status.paired = false; accountName = nil; status.history = []; words = [] }
        if let result = try? await c.request("/api/releases"), let entries = result["items"] as? [[String: Any]], let mac = entries.first(where: { $0["platform"] as? String == "mac" }) {
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if let version = mac["version"] as? String, version.compare(current, options: .numeric) == .orderedDescending { updateVersion = version }
        }
        AppIcon.apply(status)
    }
    func toggleRecording() { status.phase == .recording ? finishRecording() : startRecording() }
    func startRecording() {
        guard ready else { message = "請先完成配對、權限與伺服器檢查"; renderIsland(); return }
        guard status.phase == .idle, !busy, retryURL == nil else { message = "請先重試或清除上次錄音"; return }
        learningTask?.cancel(); learning = nil
        target = NativePaste.capture()
        let recorder = NativeRecorder()
        do {
            try recorder.start(); self.recorder = recorder; status.phase = .recording; status.recordingSince = Date(); message = ""
            NSSound(named: "Tink")?.play(); renderIsland()
            let session = UUID(); operation = session
            Task { try? await Task.sleep(for: .seconds(180)); if operation == session && status.phase == .recording { finishRecording() } }
        } catch { recorder.cancel(); message = error.localizedDescription }
    }
    func finishRecording() {
        guard status.phase == .recording, let recorder else { return }
        do { let url = try recorder.stop(); self.recorder = nil; upload(url, target: target) }
        catch {
            if let url = recorder.url {
                retryURL = url; UserDefaults.standard.set(url.path, forKey: "retryRecording")
            }
            self.recorder = nil; status.phase = .idle; message = error.localizedDescription; renderIsland()
        }
    }
    func cancelRecording() {
        guard status.phase == .recording else { return }
        operation = UUID(); recorder?.cancel(); recorder = nil; status.phase = .idle; status.recordingSince = nil
        message = "已取消，沒有送出辨識"; renderIsland()
    }
    func retry() { if let url = retryURL { upload(url, target: nil) } }
    func discardRetry() { if let url = retryURL { try? FileManager.default.removeItem(at: url) }; retryURL = nil; UserDefaults.standard.removeObject(forKey: "retryRecording") }
    private func upload(_ url: URL, target: NativePaste.Target?) {
        status.phase = .transcribing; status.recordingSince = nil; busy = true; renderIsland()
        retryURL = url; UserDefaults.standard.set(url.path, forKey: "retryRecording")
        let c = client
        uploadTask = Task {
            defer { busy = false; status.phase = .idle; renderIsland() }
            do {
                let data = try Data(contentsOf: url)
                let result = try await c.request("/api/transcribe", audio: data, threshold: status.localThreshold)
                let text = result["text"] as? String
                status.last = LastResult(kind: text == nil ? .skipped : .ok, text: text, seconds: result["seconds"] as? Double, reason: result["reason"] as? String, gate: Gate(result["gate"] as? String), at: Date())
                if let text, !text.isEmpty {
                    if let target, NativePaste.paste(text, to: target) {
                        message = "已輸入"; monitorEdits(target, inserted: text)
                    } else { message = "目標已改變或無法確認；結果已保留，請按複製" }
                    NSSound(named: "Pop")?.play()
                } else { message = result["reason"] as? String ?? "沒有辨識到內容" }
                discardRetry(); status.history = await c.history()
            } catch { message = "辨識未完成，錄音已保留，可重試：\(error.localizedDescription)" }
        }
    }
    func copyLast() { if let text = status.last?.text { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); message = "已複製" } }
    func setThreshold(_ value: Double?) { status.localThreshold = value; if let value { UserDefaults.standard.set(value, forKey: "nativeThreshold") } else { UserDefaults.standard.set(-1.0, forKey: "nativeThreshold"); status.localThreshold = nil } }
    func refreshVocab() async { if let d = try? await client.request("/api/vocab") { words = d["words"] as? [String] ?? [] } }
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
        island?.update(phase: status.phase, since: status.recordingSince, message: text, asking: learning != nil)
        AppIcon.apply(status)
    }
}
