import AppKit
import SwiftUI

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = StatusStore.shared

    var body: some Scene {
        Window("超簡單語音輸入", id: "main") {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }   // 這個 App 沒有「新增」的概念
            CommandGroup(after: .toolbar) {
                Button("立即重新整理") { store.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        MenuBarExtra("超簡單語音輸入", systemImage: store.status.phase == .recording ? "mic.fill" : "waveform") {
            Button("開啟面板") { store.showPanel() }
            Button(store.status.phase == .recording ? "結束並辨識" : "開始錄音") { store.toggleRecording() }
            Button("取消錄音") { store.cancelRecording() }.disabled(store.status.phase != .recording)
            Divider()
            Button("帳號與裝置") { store.openWebVersion() }
            Button("下載與更新") { store.openDownload() }
            Button("結束 App") { NSApp.terminate(nil) }
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 關掉視窗不等於關掉 App。
    ///
    /// 這是「要在 Dock 裡」的重點：圖示留著，狀態才看得到——熱鍵壞掉時，Dock 上
    /// 那個帶斜線的圖示就是唯一會主動告訴你的東西。真的要離開用 Cmd+Q。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 點 Dock 圖示時把視窗叫回來。沒有這段，視窗關掉之後就再也開不出來了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            StatusStore.shared.showPanel()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.regular)   // 確保出現在 Dock 與 Cmd+Tab
        // Recording, shortcuts and account loading must also start for login/background launches.
        StatusStore.shared.start()
    }
}
