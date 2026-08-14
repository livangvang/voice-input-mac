import AppKit
import SwiftUI

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = StatusStore()

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
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)   // 確保出現在 Dock 與 Cmd+Tab
    }
}
