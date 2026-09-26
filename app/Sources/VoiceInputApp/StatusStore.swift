import AppKit
import Combine
import SwiftUI

/// 畫面狀態的單一來源。
///
/// 三種資料的變化速度差很多，所以用三個節奏：
///   - 本地狀態（$TMPDIR 的四個檔）0.5 秒——錄音秒數要跳得順
///   - 熱鍵健康度 3 秒——Hammerspoon 掛掉是分鐘級的事件，但也不能等太久才發現
///   - 伺服器與歷史 15 秒——每次都是一趟 Tailscale 來回，太密集只是浪費
///
/// 全部用輪詢，不用 FSEvents：檔案很小、間隔很鬆，而 FSEvents 會合併事件，
/// 當唯一來源會漏。core.lua 也是同一個結論（pathwatcher 只當最佳化）。
@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var status = AppStatus()
    @Published private(set) var busy = false

    private var localTimer: Timer?
    private var probeTimer: Timer?
    private var remoteTimer: Timer?
    private let client = SparkClient(base: StatusReader.server())

    func start() {
        refreshLocal()
        Task { await refreshProbe() }
        Task { await refreshRemote() }

        localTimer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLocal() }
        }
        probeTimer = .scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshProbe() }
        }
        remoteTimer = .scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRemote() }
        }
    }

    func stop() {
        [localTimer, probeTimer, remoteTimer].forEach { $0?.invalidate() }
        localTimer = nil; probeTimer = nil; remoteTimer = nil
    }

    // MARK: - 更新

    private func refreshLocal() {
        var s = status
        s.phase = StatusReader.phase()
        s.recordingSince = StatusReader.recordingSince()
        s.last = StatusReader.lastResult()
        s.localThreshold = Sensitivity.local()
        status = s
        AppIcon.apply(status)
    }

    /// 上次查權限的時間。權限是使用者手動改的設定，幾乎不會變——
    /// 每 3 秒 fork 一個 hs 進程去問它，代價遠大於它的資訊量。
    private var lastAXCheck = Date.distantPast

    private func refreshProbe() async {
        // Hammerspoon 在不在跑：純記憶體查詢，很便宜，維持 3 秒一次。
        // 它掛掉是真正要立刻知道的事。
        let running = SystemProbe.hammerspoonRunning()
        let wasRunning = status.hammerspoonRunning
        var s = status
        s.hammerspoonRunning = running
        status = s

        // 權限：剛啟動、剛從沒跑變成在跑、或距上次超過 30 秒才查。
        let justCameUp = running && !wasRunning
        let stale = Date().timeIntervalSince(lastAXCheck) > 30
        if running && (justCameUp || stale) {
            lastAXCheck = Date()
            let ax = await SystemProbe.accessibilityGranted()
            var s2 = status
            s2.accessibilityGranted = ax
            status = s2
        } else if !running {
            var s2 = status
            s2.accessibilityGranted = nil   // 沒在跑就無從查起，不要留著舊答案
            status = s2
        }

        AppIcon.apply(status)
    }

    private func refreshRemote() async {
        let health = await client.health()
        var s = status
        s.serverReachable = health != nil
        s.whisperReady = health?.whisperReady
        s.threshold = health?.threshold
        s.serverCheckedAt = Date()
        status = s

        // 連不上就不要再問歷史，只是多等一次逾時。
        if health != nil {
            let items = await client.history()
            var s2 = status
            s2.history = items
            status = s2
        }
        AppIcon.apply(status)
    }

    // MARK: - 動作

    func toggleRecording() {
        Task {
            busy = true
            defer { busy = false }
            await SystemProbe.voiceInput("toggle")
            refreshLocal()
            // 辨識完歷史會多一筆，但伺服器要一點時間寫入，等一下再抓。
            try? await Task.sleep(for: .seconds(1))
            await refreshRemote()
        }
    }

    func cancelRecording() {
        Task {
            await SystemProbe.voiceInput("cancel", timeout: 15)
            refreshLocal()
        }
    }

    func launchHammerspoon() {
        SystemProbe.launchHammerspoon()
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refreshProbe()
        }
    }

    func reloadHammerspoon() {
        Task {
            busy = true
            defer { busy = false }
            await SystemProbe.reloadHammerspoon()
            try? await Task.sleep(for: .seconds(2))
            await refreshProbe()
        }
    }

    /// 設定這台的靈敏度覆蓋值；nil＝改回跟著 Spark 全域值。
    /// 寫完立刻重讀本地狀態，滑桿才不會彈回舊值再跳到新值。
    func setThreshold(_ value: Double?) {
        Sensitivity.setLocal(value)
        refreshLocal()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openWebVersion() {
        guard let url = URL(string: StatusReader.server()) else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshNow() {
        refreshLocal()
        Task { await refreshProbe() }
        Task { await refreshRemote() }
    }
}
