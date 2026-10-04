import SwiftUI

struct PanelSettingsView: View {
    @EnvironmentObject var store: StatusStore
    @State private var serverInput = ""
    private var s: AppStatus { store.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            account
            computer
            connection
            if !store.message.isEmpty {
                Text(store.message).font(.callout).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        }
        .font(.system(size: 16))
        .controlSize(.large)
        .onAppear { serverInput = store.server }
    }

    private var account: some View {
        SettingsSection("帳號與裝置") {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.accountName ?? "尚未配對這台 Mac").font(.system(size: 17, weight: .medium))
                if store.credentialLoading { SettingsHelp("正在讀取這台電腦的帳號憑證…") }
                if store.credentialNeedsApproval {
                    SettingsHelp("更新後需要重新允許 App 存取 Keychain 裡的帳號。伺服器連線仍可獨立檢查。")
                    Button("恢復帳號存取") { store.restoreAccountAccess() }
                }
                if s.paired {
                    Button("管理帳號與裝置") { store.openWebVersion() }
                } else {
                    Button(store.pairCode == nil ? "連結我的帳號" : "再次開啟確認頁") { store.linkAccount() }
                    SettingsHelp("網頁會自動帶入這台 Mac。確認帳號與電腦，按「允許連結」即可，不必複製配對碼。")
                    if let code = store.pairCode {
                        DisclosureGroup("手動連結（需要時使用）") {
                            Text(code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                            SettingsHelp("若帳號在另一個瀏覽器登入，請回到該瀏覽器的帳號頁使用這組碼。十分鐘內有效。")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var computer: some View {
        SettingsSection("這台電腦") {
            VStack(alignment: .leading, spacing: 12) {
                Text("收音裝置：\(store.microphoneName)（系統預設）")
                CheckRow(title: "麥克風", detail: s.microphoneGranted ? "已授權" : "需要你的授權", state: s.microphoneGranted ? .ok : .bad,
                         action: s.microphoneGranted ? nil : ("授權", { store.requestMicrophone() }), titleSize: 16, detailSize: 14)
                CheckRow(title: "輔助使用與快捷鍵", detail: s.nativeHotkeysRunning ? "已就緒" : "需要授權或完成舊版遷移", state: s.nativeHotkeysRunning ? .ok : .bad,
                         action: s.nativeHotkeysRunning ? nil : ("開系統設定", { store.requestAccessibility(); store.openAccessibilitySettings() }), titleSize: 16, detailSize: 14)
                Toggle("使用雙按 Ctrl", isOn: Binding(get: { store.doubleControl }, set: { store.configureHotkey($0) }))
                Picker("開始／結束快捷鍵", selection: Binding(get: { store.shortcut }, set: { store.configureShortcut($0) })) {
                    ForEach(RecordingShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("登入時啟動", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                if s.usesVoiceDetection {
                    SettingsHelp("自動辨別人聲，不需要調整音量門檻。背景音太強時仍可能影響文字準確度。")
                } else {
                    SensitivityCard(local: s.localThreshold, global: s.threshold, lastP95: s.last?.gate?.p95, onChange: { store.setThreshold($0) })
                }
                if store.legacyPending {
                    SettingsHelp("已找到 Hammerspoon 語音模組。先備份並停用它，再啟用新版快捷鍵，避免重複錄音。")
                    Button("備份並停用舊版語音模組") { store.migrateLegacy() }
                }
                if store.needsLegacyReload {
                    Button("已在 Hammerspoon 完成 Reload Config") { store.confirmLegacyReload() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connection: some View {
        SettingsSection("連線與安裝") {
            VStack(alignment: .leading, spacing: 12) {
                CheckRow(title: "Tailscale 與 Spark", detail: connectionDetail, state: connectionState,
                         action: ("重新檢查", { store.refreshNow() }), titleSize: 16, detailSize: 14)
                if s.serverReachable == true && s.whisperReady != true && s.paired {
                    Button("喚醒辨識服務") { store.wakeServer() }
                }
                TextField("Spark HTTPS 網址", text: $serverInput)
                Button("儲存伺服器網址") { store.setServer(serverInput) }.disabled(s.phase != .idle)
                Divider()
                if let version = store.updateVersion { Button("下載新版本 \(version)") { store.openDownload() } }
                Button("下載與安裝說明") { store.openDownload() }
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 14)).foregroundStyle(Theme.dim).padding(.leading, 12)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionDetail: String {
        guard let reachable = s.serverReachable else { return "正在檢查連線…" }
        guard reachable else { return "連不上，請確認 Tailscale 已連線" }
        guard let whisperReady = s.whisperReady else { return "已連線，正在檢查辨識服務…" }
        return whisperReady ? "辨識服務就緒" : "已連線，辨識服務尚未就緒"
    }

    private var connectionState: CheckRow.State {
        guard let reachable = s.serverReachable else { return .unknown }
        guard reachable else { return .bad }
        guard let whisperReady = s.whisperReady else { return .unknown }
        return whisperReady ? .ok : .bad
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 18, weight: .semibold))
            content.padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardEdge, lineWidth: 1))
    }
}

private struct SettingsHelp: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Theme.dim)
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 12)
    }
}
