import Foundation

/// 這台 Mac 自己的靈敏度門檻（SPEECH_ABS_THOLD）。
///
/// 讀寫同一份 ~/.config/voice-input/config，跟 `voice-input-mac.sh thold`、
/// 面板裡的靈敏度輸入框是同一個值——三個介面調的都是同一個數字，改一個
/// 下次口述其他兩個也會看到新值。
///
/// 留白／nil＝沒有覆蓋值，跟著 Spark 的全域門檻。
enum Sensitivity {
    static let min: Double = 80
    static let max: Double = 16000

    /// 讀目前這台的覆蓋值。沒設定、檔案不存在、格式壞掉都回 nil——
    /// 跟 bash 版一樣，讀不到就當「沒有覆蓋」，不擋著使用者用全域值。
    static func local() -> Double? {
        guard let text = try? String(contentsOf: Paths.config, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("SPEECH_ABS_THOLD=") else { continue }
            var v = String(t.dropFirst("SPEECH_ABS_THOLD=".count))
            if let hashIdx = v.firstIndex(of: "#") { v = String(v[v.startIndex..<hashIdx]) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return Double(v)
        }
        return nil
    }

    /// 寫入覆蓋值；nil＝拿掉覆蓋，改回跟著全域值。
    ///
    /// 濾掉舊的 SPEECH_ABS_THOLD 那一行、把新的附在最後，其他設定原封不動——
    /// 跟 `voice-input-mac.sh thold` 同一套作法，兩邊寫出來的檔案格式才不會打架。
    /// 範圍外的值直接拒絕（回 false），不夾到邊界：滑桿本身已經限制在範圍內，
    /// 這裡只是最後一道防線。
    @discardableResult
    static func setLocal(_ value: Double?) -> Bool {
        if let value, !(min...max).contains(value) { return false }

        let dir = Paths.config.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: Paths.config, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SPEECH_ABS_THOLD=") }
        while lines.last == "" { lines.removeLast() }

        if let value {
            lines.append("SPEECH_ABS_THOLD=\"\(Int(value))\"   # 這台 Mac 自己的門檻（Mac App 設定）")
        }

        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return (try? text.write(to: Paths.config, atomically: true, encoding: .utf8)) != nil
    }
}
