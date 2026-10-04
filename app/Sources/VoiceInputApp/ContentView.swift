import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: StatusStore
    @State private var serverInput = ""
    @State private var newWord = ""
    @State private var edited = ""
    @State private var editing = false
    private var s: AppStatus { store.status }
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("超簡單語音輸入").font(.headline); Spacer(); Text(s.phase.label).foregroundStyle(s.phase == .recording ? Theme.accent : Theme.dim) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.ready ? "可以用" : "完成下面的檢查，就能開始說話").font(.title3.bold())
                            Text(store.doubleControl ? "雙按 Ctrl 開始 · 單按 Ctrl 結束並辨識 · Esc 取消" : "Ctrl+Option+V 開始／結束 · Esc 取消").font(.caption)
                            Text("使用快捷鍵時，文字會輸入原本的欄位。從此視窗試說，結果會保留供複製。").font(.caption).foregroundStyle(Theme.dim)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("帳號") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.accountName ?? "尚未配對這台 Mac")
                            if store.credentialLoading { Text("正在讀取這台電腦的帳號憑證…").font(.caption) }
                            if store.credentialNeedsApproval {
                                Text("更新後需要重新允許 App 存取 Keychain 裡的帳號。伺服器連線仍可獨立檢查。").font(.caption)
                                Button("恢復帳號存取") { store.restoreAccountAccess() }
                            }
                            if store.status.paired {
                                Button("帳號與裝置") { store.openWebVersion() }
                            } else {
                                Button(store.pairCode == nil ? "連結我的帳號" : "再次開啟確認頁") { store.linkAccount() }
                                Text("網頁會自動帶入這台 Mac。確認帳號與電腦，按「允許連結」即可，不必複製配對碼。").font(.caption)
                                if let code = store.pairCode {
                                    DisclosureGroup("手動連結（需要時使用）") {
                                        Text(code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                                        Text("若帳號在另一個瀏覽器登入，請回到該瀏覽器的帳號頁使用這組碼。十分鐘內有效。").font(.caption)
                                    }
                                }
                            }
                            if let version = store.updateVersion { Button("下載新版本 \(version)") { store.openDownload() } }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    CheckRow(title: "麥克風", detail: s.microphoneGranted ? "已授權" : "需要你的授權", state: s.microphoneGranted ? .ok : .bad, action: s.microphoneGranted ? nil : ("授權", { store.requestMicrophone() }))
                    CheckRow(title: "輔助使用與快捷鍵", detail: s.nativeHotkeysRunning ? "已就緒" : "需要授權或完成舊版遷移", state: s.nativeHotkeysRunning ? .ok : .bad, action: s.nativeHotkeysRunning ? nil : ("開設定", { store.requestAccessibility(); store.openAccessibilitySettings() }))
                    CheckRow(title: "Tailscale 與 Spark", detail: s.serverReachable == true ? (s.whisperReady == true ? "辨識服務就緒" : "已連線，辨識服務尚未就緒") : "連不上，請確認 Tailscale 已連線", state: s.serverReachable == true && s.whisperReady == true ? .ok : .bad, action: ("重查", { store.refreshNow() }))
                    if s.serverReachable == true && s.whisperReady != true && s.paired { Button("喚醒辨識服務") { store.wakeServer() } }
                    if store.legacyPending { GroupBox("舊版遷移") { VStack(alignment: .leading) { Text("已找到 Hammerspoon 語音模組。先備份並停用它，再啟用新版快捷鍵，避免重複錄音。"); Button("備份並停用舊版語音模組") { store.migrateLegacy() } } } }
                    if store.needsLegacyReload { Button("已在 Hammerspoon 完成 Reload Config") { store.confirmLegacyReload() } }
                    if !store.message.isEmpty { Text(store.message).font(.callout).foregroundStyle(Theme.warn).textSelection(.enabled) }
                    if store.retryURL != nil {
                        DisclosureGroup("保留錄音（需要時重試）") {
                            VStack(alignment: .leading, spacing: 8) {
                                if store.canRetryConfirmedSpeech {
                                    Text("音量足夠，但被防噪判定擋下。如果這段確實有說話，可重新辨識；只對這一次放寬判定。").font(.caption)
                                    Button("這次有說話，重新辨識") { store.retry(speechConfirmed: true) }.disabled(store.busy)
                                } else { Button("重試上次錄音") { store.retry() }.disabled(store.busy) }
                                Text("可直接用快捷鍵再說一次，不必先處理上一段。較早的失敗錄音會保留在這台電腦。").font(.caption).foregroundStyle(Theme.dim)
                                HStack {
                                    Button("重新錄一段") { store.recordAgain() }.disabled(store.busy || !store.ready)
                                    Button("清除錄音", role: .destructive) { store.discardRetry() }.disabled(store.busy)
                                }
                                Button("查看較早保留的錄音") { store.openSavedRecordings() }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let last = s.last { LastResultCard(result: last); HStack { Button("複製結果") { store.copyLast() }; Button("修正並學習") { edited = last.text ?? ""; editing = true }.disabled(last.text == nil) } }
                    if let learning = store.learning { GroupBox("學習提示") { VStack(alignment: .leading) { Text("\(learning.bad) → \(learning.good)"); Text("確認後會套用到以後的辨識。").font(.caption); HStack { Button("學起來") { store.saveLearning() }; Button("略過") { store.dismissLearning() } } } } }
                    if s.usesVoiceDetection {
                        GroupBox("自動辨別人聲") {
                            Text("會判斷錄音裡是否有人說話，不需要調整音量門檻。背景音太強時仍可能影響文字準確度。")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        SensitivityCard(local: s.localThreshold, global: s.threshold, lastP95: s.last?.gate?.p95, onChange: { store.setThreshold($0) })
                    }
                    DisclosureGroup("我的詞彙：\(store.words.count) 個（全表讀音比對）") {
                        VStack(alignment: .leading) {
                            HStack { TextField("加入常用詞", text: $newWord); Button("加入") { store.addWord(newWord); newWord = "" }.disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || !s.paired) }
                            ForEach(store.words, id: \.self) { word in HStack { Text(word); Spacer(); Button("移除") { store.removeWord(word) } } }
                        }
                    }
                    GroupBox("這台電腦的設定") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("收音裝置：\(store.microphoneName)（系統預設）").font(.caption)
                            Toggle("使用雙按 Ctrl", isOn: Binding(get: { store.doubleControl }, set: { store.configureHotkey($0) }))
                            Picker("開始／結束快捷鍵", selection: Binding(get: { store.shortcut }, set: { store.configureShortcut($0) })) {
                                ForEach(RecordingShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            Toggle("登入時啟動", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                            TextField("Spark HTTPS 網址", text: $serverInput)
                            Button("儲存伺服器網址") { store.setServer(serverInput) }
                            Button("下載與安裝說明") { store.openDownload() }
                        }
                    }
                    if !s.history.isEmpty { GroupBox("我的最近辨識") { VStack(alignment: .leading, spacing: 10) { ForEach(s.history) { item in HStack(alignment: .top) { Text(item.time).font(.caption.monospaced()); Text(item.text).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading) } }
                }.padding(20)
            }
        }
        .foregroundStyle(Theme.fg)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 620, idealHeight: 760)
        .toolbar {
            Button(s.phase == .recording ? "結束並辨識" : "試說一句") { store.toggleRecording() }.disabled(s.phase == .transcribing || (!store.ready && s.phase != .recording))
            if s.phase == .recording { Button("取消", role: .destructive) { store.cancelRecording() } }
            Button("重新檢查") { store.refreshNow() }
        }
        .onAppear { serverInput = store.server; store.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stop() }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 14) { Text("修改辨識結果").font(.headline); TextEditor(text: $edited).frame(width: 420, height: 120); HStack { Button("取消") { editing = false }; Button("比較修改") { store.learn(original: s.last?.text ?? "", edited: edited); editing = false } } }.padding(20)
        }
    }
}
