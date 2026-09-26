import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: StatusStore

    private var s: AppStatus { store.status }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    verdict
                    checks
                    sensitivity
                    lastResult
                    history
                }
                .padding(18)
            }
        }
        .frame(minWidth: 380, idealWidth: 400, minHeight: 560, idealHeight: 680)
        .toolbar { toolbarItems }
        .onAppear { store.start() }
    }

    // MARK: - 標題

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("超簡單語音輸入")
                .font(.system(size: 15, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.fg)
            Spacer()
            Text(phaseText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(s.phase == .recording ? Theme.accent : Theme.dim)
        }
    }

    private var phaseText: String {
        if let e = s.elapsed { return String(format: "收音中 %.0fs", e) }
        return s.phase.label
    }

    // MARK: - 一句話結論

    /// 整個 App 的重點：現在按下去到底有沒有用。
    /// 其他細節都是為了回答「不能用的話是哪裡壞了」。
    private var verdict: some View {
        let serverOK = s.serverReachable ?? false

        let (dot, title, sub): (Color, String, String) = {
            switch s.hotkeyState {
            case .broken:
                return (Theme.bad, "現在按熱鍵不會有反應", "看下面哪一項是紅的")
            case .unknown:
                return (Theme.dimmer, "熱鍵狀態查不到",
                        "Hammerspoon 沒回應查詢，不代表熱鍵壞了——直接按按看最準")
            case .working:
                return serverOK
                    ? (Theme.good, "可以用", "連按兩下 Ctrl 開始講話，按任何一個鍵結束")
                    : (Theme.warn, "熱鍵可用，但連不到 Spark", "錄得起來，但辨識不會有結果")
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.fg)
            }
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardEdge, lineWidth: 1))
    }

    // MARK: - 三項檢查

    private var checks: some View {
        VStack(spacing: 8) {
            CheckRow(
                title: "Hammerspoon",
                detail: s.hammerspoonRunning ? "執行中" : "沒在跑，熱鍵完全不會有反應",
                state: s.hammerspoonRunning ? .ok : .bad,
                action: s.hammerspoonRunning ? nil : ("啟動", { store.launchHammerspoon() })
            )

            CheckRow(
                title: "輔助使用權限",
                detail: accessibilityDetail,
                state: accessibilityState,
                action: (s.accessibilityGranted == false)
                    ? ("開設定", { store.openAccessibilitySettings() }) : nil
            )

            CheckRow(
                title: "Spark 伺服器",
                detail: serverDetail,
                state: (s.serverReachable ?? false) ? .ok : (s.serverReachable == nil ? .unknown : .bad),
                action: nil
            )
        }
    }

    private var accessibilityDetail: String {
        switch s.accessibilityGranted {
        case .some(true): return "已授權"
        case .some(false): return "沒授權，收不到按鍵事件"
        case .none: return s.hammerspoonRunning ? "問不到（IPC 沒通）" : "Hammerspoon 沒在跑，無從查起"
        }
    }

    private var accessibilityState: CheckRow.State {
        switch s.accessibilityGranted {
        case .some(true): return .ok
        case .some(false): return .bad
        case .none: return .unknown
        }
    }

    private var serverDetail: String {
        guard let reachable = s.serverReachable else { return "檢查中…" }
        if !reachable { return "連不上（Tailscale？MagicDNS 有打勾嗎）" }
        let whisper = (s.whisperReady ?? false) ? "whisper 就緒" : "whisper 未就緒"
        if let t = s.threshold { return "\(whisper)．靈敏度門檻 \(Int(t))" }
        return whisper
    }

    // MARK: - 靈敏度

    private var sensitivity: some View {
        SensitivityCard(
            local: s.localThreshold,
            global: s.threshold,
            lastP95: s.last?.gate?.p95,
            onChange: { store.setThreshold($0) }
        )
    }

    // MARK: - 最後一次結果

    @ViewBuilder
    private var lastResult: some View {
        if let last = s.last {
            LastResultCard(result: last)
        }
    }

    // MARK: - 歷史

    @ViewBuilder
    private var history: some View {
        if !s.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近辨識")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.dimmer)

                VStack(spacing: 0) {
                    ForEach(s.history) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.dimmer)
                            if item.fromWeb {
                                Text("🌐").font(.system(size: 10))
                            }
                            Text(item.text)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 6)
                        if item.id != s.history.last?.id {
                            Divider().overlay(Theme.cardEdge)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardEdge, lineWidth: 1))
            }
        }
    }

    // MARK: - 工具列

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                s.phase == .recording ? store.cancelRecording() : store.toggleRecording()
            } label: {
                Label(s.phase == .recording ? "停止" : "開始錄音",
                      systemImage: s.phase == .recording ? "stop.circle" : "mic.circle")
            }
            .disabled(store.busy && s.phase != .recording)

            Button { store.reloadHammerspoon() } label: {
                Label("重載設定", systemImage: "arrow.clockwise")
            }
            .disabled(!s.hammerspoonRunning)

            Button { store.openWebVersion() } label: {
                Label("網頁版", systemImage: "safari")
            }
        }
    }
}
