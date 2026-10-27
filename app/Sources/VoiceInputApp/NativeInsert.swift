import AppKit
import ApplicationServices

/// 把辨識結果送進輸入框，盡量不動使用者的剪貼簿。
///
/// 使用者的習慣是「先複製網址 → 口述一段 → 再貼網址」。貼上要借剪貼簿的話，
/// 借的那幾秒裡他一按 Cmd+V 就貼到口述的字，網址被蓋掉。所以分兩招：
///
///   1. 直接寫進輸入框（輔助使用 API 設 AXSelectedText）——完全不碰剪貼簿。
///      寫完讀回來確認真的進去了才算數。系統內建 App 多半吃這招。
///   2. 不吃第 1 招的 App（Electron、Chromium 網頁）才借剪貼簿 + Cmd+V，
///      而且剪貼簿是「有人來讀才交出內容」：輸入框一讀走就馬上還原，通常不到 0.2 秒。
///
/// 第 1 招失敗過的 App 記起來，下次直接走第 2 招——試一次多花的時間和重複插入的風險都只付一次。
@MainActor
enum DirectInsert {
    private static let memoryKey = "directInsertUnsupported"
    /// 已知不吃第 1 招、或吃了也不可靠的 App：Electron 和 Chromium 系的輸入框常常回報成功卻沒寫進去，
    /// 那樣會接著走第 2 招，同一段字就出現兩次。先排除掉，不拿使用者的輸入去試。
    static let knownUnsupported: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.google.Chrome", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.tinyspeck.slackmacgap", "md.obsidian",
        "notion.id", "com.anthropic.claudefordesktop", "com.hnc.Discord", "jp.naver.line.mac",
        "com.openai.chat", "com.figma.Desktop",
    ]

    static func supported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if knownUnsupported.contains(bundleID) { return false }
        return !(UserDefaults.standard.stringArray(forKey: memoryKey) ?? []).contains(bundleID)
    }

    static func remember(unsupported bundleID: String?) {
        guard let bundleID else { return }
        var list = UserDefaults.standard.stringArray(forKey: memoryKey) ?? []
        if !list.contains(bundleID) { list.append(bundleID); UserDefaults.standard.set(list, forKey: memoryKey) }
    }

    /// 寫入前後的全文比一比：有變、而且新的全文裡有這段字，才算真的寫進去。
    nonisolated static func looksInserted(before: String, after: String?, text: String) -> Bool {
        guard let after else { return false }
        return after != before && after.contains(text)
    }

    /// 回傳 true＝確定寫進去了。false＝什麼都沒發生（可以放心改走剪貼簿，不會重複）。
    static func attempt(_ text: String, into field: AXUIElement) async -> Bool {
        // 讀不到原本的全文就沒辦法確認，寧可不試：試了卻判斷錯，接著走剪貼簿就會插兩次。
        guard let before = NativePaste.value(field) else { return false }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // 有些 App 寫入是非同步的，給它一點時間再讀
        for _ in 0..<3 {
            if looksInserted(before: before, after: NativePaste.value(field), text: text) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }
}

/// 剪貼簿的「承諾」：內容不先放上去，等輸入框真的來讀才交出，交出後通知還原。
final class PastePromise: NSObject, NSPasteboardItemDataProvider {
    let text: String
    private(set) var read = false
    init(_ text: String) { self.text = text }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        read = true
    }
}

extension NativePaste {
    /// 剪貼簿管理軟體（Raycast、Paste…）照 nspasteboard.org 的慣例，看到這個類型就不記、不讀。
    /// 不標的話，它們會比輸入框先來讀，害我們太早還原。
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// 輸入框讀走之後再多等一下才還原：有些 App 會分兩次讀（純文字、再讀一次確認）。
    static let restoreAfterRead: Duration = .milliseconds(300)

    /// 送進輸入框：先試直接寫入，不行才借剪貼簿。回傳 true＝已送出。
    static func deliver(_ text: String, to target: Target) async -> Bool {
        guard sameFocus(target, requireSelection: true) else { return false }
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        if let field = target.field, DirectInsert.supported(bundleID) {
            if await DirectInsert.attempt(text, into: field) { return true }
            DirectInsert.remember(unsupported: bundleID)
        }
        return await paste(text, to: target)
    }

    /// 借剪貼簿貼上。剪貼簿用承諾的方式放：輸入框來讀才交出內容，讀走後 restoreAfterRead 就還原；
    /// 一直沒人讀（沒貼成功）最晚 restoreDelay 也會還原。
    static func paste(_ text: String, to target: Target) async -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        let deadline = ContinuousClock.now + modifierWait
        while modifiersHeld(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let board = NSPasteboard.general
        let old = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let promise = PastePromise(text)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        item.setData(Data(), forType: transientType)
        board.clearContents(); board.writeObjects([item])
        let count = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        let stillFocused = sameFocus(target, requireSelection: true)
        if stillFocused {
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(for: keyGap)
            up.post(tap: .cghidEventTap)
        }
        Task { @MainActor in
            let giveUp = ContinuousClock.now + restoreDelay
            while !promise.read, ContinuousClock.now < giveUp { try? await Task.sleep(for: .milliseconds(30)) }
            if promise.read { try? await Task.sleep(for: restoreAfterRead) }
            // 內容還是我們寫的那份才還原：使用者可能在這段時間複製了別的東西
            if board.changeCount == count { board.clearContents(); if !old.isEmpty { board.writeObjects(old) } }
        }
        return stillFocused
    }
}
