import AppKit
import Foundation

/// 探測「熱鍵到底能不能用」，以及代為執行 .sh。
///
/// 這是這個 App 存在的理由：選單列圖示是 Hammerspoon 畫的，Hammerspoon 沒在跑
/// 的時候圖示會一起消失——於是最需要被告知的那個故障，剛好是唯一看不到的。
/// 這支 App 獨立於 Hammerspoon，所以看得到。
enum SystemProbe {
    static let hammerspoonBundleID = "org.hammerspoon.Hammerspoon"

    /// hs CLI 的候選位置。Homebrew 在 Apple Silicon 是 /opt/homebrew，
    /// Intel 是 /usr/local；App 不繼承 shell 的 PATH，所以只能自己找。
    private static let hsCandidates = [
        "/opt/homebrew/bin/hs",
        "/usr/local/bin/hs",
    ]

    static var hsPath: String? {
        hsCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func hammerspoonRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: hammerspoonBundleID).isEmpty
    }

    /// Hammerspoon 有沒有拿到「輔助使用」權限。
    ///
    /// 沒有公開 API 可以查**別的 App** 的權限（AXIsProcessTrusted 查的是自己），
    /// 所以改成透過 IPC 問 Hammerspoon 本人。它沒在跑就問不到，回 nil 而不是 false：
    /// 「不知道」和「沒有權限」是兩件事，畫面上不該混為一談。
    static func accessibilityGranted() async -> Bool? {
        guard hammerspoonRunning(), let hs = hsPath else { return nil }
        let out = await run(hs, ["-t", "3", "-c", "return tostring(hs.accessibilityState())"],
                            timeout: 6)
        guard let out else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "true" { return true }
        if t == "false" { return false }
        return nil   // IPC 沒通（沒 require("hs.ipc") 或剛 reload），一樣是「不知道」
    }

    static func launchHammerspoon() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hammerspoonBundleID)
        else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    static func reloadHammerspoon() async {
        guard let hs = hsPath else { return }
        // reload 會把 IPC 打掉重建，這個呼叫必然拿不到回應。逾時就是正常結束，
        // 不是錯誤——所以 timeout 設短一點，不要讓 UI 等在那裡。
        _ = await run(hs, ["-t", "2", "-c", "hs.reload()"], timeout: 4)
    }

    /// 執行 voice-input-mac.sh。
    ///
    /// 錄音是 sox 在跑，而 sox 是這支 App 的子行程——macOS 會把麥克風權限算在
    /// **App** 頭上，不是 sox。所以 Info.plist 一定要有 NSMicrophoneUsageDescription，
    /// 否則從 App 按下錄音會被系統直接擋掉，而且不會有任何提示。
    @discardableResult
    static func voiceInput(_ action: String, timeout: TimeInterval = 90) async -> String? {
        let path = Paths.script.path
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return await run(path, [action], timeout: timeout)
    }

    /// 跑一個外部指令，逾時就砍掉。
    ///
    /// 逾時保護不是防禦性寫法而已：`hs -c` 在 Hammerspoon 沒在跑的時候會**永遠**
    /// 等下去（等一個不會有人回應的 message port），沒有這層保護，App 會直接凍住。
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: launchPath)
                task.arguments = args
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()

                // stdin 一定要接 /dev/null。
                //
                // 沒接的話子行程會繼承這個 App 的 stdin，而 GUI App 的 stdin 永遠不會
                // 送出 EOF——`hs` 就一直等在那裡，直到上面的逾時把它砍掉。
                //
                // 實測：stdin 繼承 = 卡 3.74 秒後被砍、輸出空字串；接 /dev/null = 0.09 秒
                // 回傳正確結果。這個差別不只是慢：權限查詢每 3 秒跑一次，每次都留一個
                // 卡住的 hs 進程掛在 Hammerspoon 的 message port 上，久了會把 IPC 弄壞，
                // 連帶讓 .sh 裡那些沒有 -t 的 `hs -c` 一起卡住——症狀是「錄音關不掉」。
                task.standardInput = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    cont.resume(returning: nil)
                    return
                }

                let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                deadline.cancel()

                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
