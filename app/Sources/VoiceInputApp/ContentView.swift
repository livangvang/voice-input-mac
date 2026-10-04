import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: StatusStore
    @State private var newWord = ""
    @State private var edited = ""
    @State private var editing = false
    private var s: AppStatus { store.status }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header.padding(20)
                Divider().overlay(Theme.cardEdge)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.panelPage == .daily {
                            dailyContent
                        } else {
                            PanelSettingsView()
                        }
                    }.padding(20)
                }.id(store.panelPage)
            }
        }
        .foregroundStyle(Theme.fg)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 620, idealHeight: 760)
        .toolbar {
            if store.panelPage == .daily {
                Button(s.phase == .recording ? "結束並辨識" : "試說一句") { store.toggleRecording() }
                    .disabled(s.phase == .transcribing || (!store.ready && s.phase != .recording))
                if s.phase == .recording { Button("取消", role: .destructive) { store.cancelRecording() } }
            }
        }
        .onAppear { store.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stop() }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("修改辨識結果").font(.headline)
                TextEditor(text: $edited).frame(width: 420, height: 120)
                HStack {
                    Button("取消") { editing = false }
                    Button("比較修改") { store.learn(original: s.last?.text ?? "", edited: edited); editing = false }
                }
            }.padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.panelPage == .settings {
                Button { store.panelPage = .daily } label: { Label("返回", systemImage: "chevron.left") }
                    .controlSize(.large).frame(minHeight: 44)
                    .accessibilityLabel("返回語音輸入主頁")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.panelPage == .daily ? "超簡單語音輸入" : "設定").font(.title2.bold())
                Text(store.panelPage == .daily ? "日常使用" : "帳號、這台電腦與連線")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            Spacer()
            if store.panelPage == .daily {
                Button { store.panelPage = .settings } label: { Label("設定", systemImage: "gearshape") }
                    .controlSize(.large).frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private var dailyContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(store.ready ? "可以用" : "尚未就緒").font(.title3.bold())
                    Spacer()
                    Text(s.phase.label).foregroundStyle(s.phase == .recording ? Theme.accent : Theme.dim)
                }
                Text(store.doubleControl ? "雙按 Ctrl 開始 · 單按 Ctrl 結束並辨識 · Esc 取消" : "\(store.shortcut.label) 開始／結束 · Esc 取消")
                    .font(.caption)
                Text("使用快捷鍵時，文字會輸入原本的欄位。從此視窗試說，結果會保留供複製。")
                    .font(.caption).foregroundStyle(Theme.dim)
                if !store.ready {
                    Button("前往設定完成檢查") { store.panelPage = .settings }.controlSize(.large)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if !store.message.isEmpty {
            Text(store.message).font(.callout).foregroundStyle(Theme.warn).textSelection(.enabled)
        }
        if let last = s.last {
            LastResultCard(result: last)
            HStack {
                Button("複製結果") { store.copyLast() }.disabled(last.text == nil)
                Button("修正並學習") { edited = last.text ?? ""; editing = true }.disabled(last.text == nil)
            }
        } else {
            GroupBox("辨識結果") {
                Text("說完第一句後，文字會顯示在這裡，可複製或修正。")
                    .font(.callout).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let learning = store.learning {
            GroupBox("學習提示") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(learning.bad) → \(learning.good)")
                    Text("確認後會套用到以後的辨識。").font(.caption)
                    HStack { Button("學起來") { store.saveLearning() }; Button("略過") { store.dismissLearning() } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if store.retryURL != nil { retainedRecording }
        DisclosureGroup("我的常用詞：\(store.words.count) 個") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("加入常用詞", text: $newWord)
                    Button("加入") { store.addWord(newWord); newWord = "" }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || !s.paired)
                }
                ForEach(store.words, id: \.self) { word in
                    HStack { Text(word); Spacer(); Button("移除") { store.removeWord(word) } }
                }
            }.padding(.top, 8)
        }
        if !s.history.isEmpty {
            GroupBox("我的最近辨識") {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(s.history) { item in
                        HStack(alignment: .top) {
                            Text(item.time).font(.caption.monospaced())
                            Text(item.text).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var retainedRecording: some View {
        DisclosureGroup("保留錄音（需要時重試）") {
            VStack(alignment: .leading, spacing: 8) {
                if store.canRetryConfirmedSpeech {
                    Text("音量足夠，但被防噪判定擋下。如果這段確實有說話，可重新辨識；只對這一次放寬判定。").font(.caption)
                    Button("這次有說話，重新辨識") { store.retry(speechConfirmed: true) }.disabled(store.busy)
                } else {
                    Button("重試上次錄音") { store.retry() }.disabled(store.busy)
                }
                Text("可直接用快捷鍵再說一次，不必先處理上一段。較早的失敗錄音會保留在這台電腦。")
                    .font(.caption).foregroundStyle(Theme.dim)
                HStack {
                    Button("重新錄一段") { store.recordAgain() }.disabled(store.busy || !store.ready)
                    Button("清除錄音", role: .destructive) { store.discardRetry() }.disabled(store.busy)
                }
                Button("查看較早保留的錄音") { store.openSavedRecordings() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }
}
