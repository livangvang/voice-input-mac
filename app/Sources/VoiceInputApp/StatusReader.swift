import Foundation

/// 讀 .sh 寫在 $TMPDIR/voice-input/ 的狀態檔。
///
/// 邏輯刻意跟 voice-input-core.lua 的 M.phase()／M.lastResult() 一致——
/// 兩個介面對同一組檔案得出不同結論的話，使用者會不知道該信哪一個。
///
/// 為什麼能讀到同一個目錄：NSTemporaryDirectory() 走 confstr(_CS_DARWIN_USER_TEMP_DIR)，
/// 跟 shell 的 $TMPDIR 是同一個 per-user 目錄。前提是 App **不開 sandbox**，
/// 一開就會被重導到 container 裡，讀到永遠空的目錄。
enum Paths {
    static let run = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("voice-input")

    static var pidfile: URL { run.appendingPathComponent("rec.pid") }
    static var phase: URL { run.appendingPathComponent("phase") }
    static var lastJSON: URL { run.appendingPathComponent("last.json") }
    static var lastNote: URL { run.appendingPathComponent("last.note") }

    static let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("bin/voice-input-mac.sh")

    static let config = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-input/config")
}

/// 綁在主執行緒上：讀的都是幾十位元組的小檔，不值得為此搬到背景還要處理同步；
/// 而 pidAlive 的快取是可變狀態，綁定 actor 之後 Swift 6 才擋得住資料競爭。
@MainActor
enum StatusReader {
    static let defaultServer = "https://spark-cb4e.taild73ae6.ts.net"

    /// 伺服器位址。先看設定檔，沒有就用預設，跟 .sh 和 core.lua 同一套規則。
    static func server() -> String {
        guard let text = try? String(contentsOf: Paths.config, encoding: .utf8) else {
            return defaultServer
        }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("SERVER=") else { continue }
            let v = String(t.dropFirst("SERVER=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !v.isEmpty { return v.hasSuffix("/") ? String(v.dropLast()) : v }
        }
        return defaultServer
    }

    private static func read(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // kill(pid, 0) 只探測行程在不在，不送訊號。EPERM 代表行程存在但不屬於我們，
    // 也算活著（實務上不會發生，但錯判成「沒在錄」比較難debug）。
    private static var aliveCache: (at: Date, val: Bool) = (.distantPast, false)
    private static func pidAlive() -> Bool {
        // 節流到 1 秒一次：UI 每 0.5 秒更新，錄音中每次都做 syscall 沒有必要。
        if Date().timeIntervalSince(aliveCache.at) < 1.0 { return aliveCache.val }
        defer { aliveCache.at = Date() }
        guard let s = read(Paths.pidfile), let pid = pid_t(s) else {
            aliveCache.val = false
            return false
        }
        let r = kill(pid, 0)
        aliveCache.val = (r == 0) || (r == -1 && errno == EPERM)
        return aliveCache.val
    }

    /// 目前階段。phase 檔可能因為程序被強制中斷而停在 recording，所以用 pidfile 覆核。
    /// 反過來不行：辨識中時 pidfile 已經被搬走了，只有 phase 知道。
    static func phase() -> Phase {
        let raw = read(Paths.phase) ?? "idle"
        switch raw {
        case "recording": return pidAlive() ? .recording : .idle
        case "transcribing": return .transcribing
        default: return .idle
        }
    }

    /// 錄音起點。pidfile 的 mtime 就是起點——.sh 一開始錄就寫這個檔。
    static func recordingSince() -> Date? {
        guard phase() == .recording else { return nil }
        return mtime(Paths.pidfile)
    }

    /// 最後一次的結果。
    ///
    /// 哪個檔新用哪個：本地錯誤（連不上、錄音太短）伺服器不知道，所以不能只看
    /// last.json，否則會把上一次成功的結果當成這次的顯示出來。
    static func lastResult() -> LastResult? {
        let jsonAt = mtime(Paths.lastJSON)
        let noteAt = mtime(Paths.lastNote)
        if jsonAt == nil && noteAt == nil { return nil }

        if let noteAt, jsonAt == nil || noteAt > jsonAt! {
            return LastResult(kind: .note, text: nil, seconds: nil,
                              reason: read(Paths.lastNote), gate: nil, at: noteAt)
        }

        guard let jsonAt,
              let raw = try? Data(contentsOf: Paths.lastJSON),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let gate = Gate(obj["gate"] as? String)

        if let err = obj["error"] as? String {
            return LastResult(kind: .error, text: nil, seconds: nil,
                              reason: err, gate: gate, at: jsonAt)
        }
        if obj["skipped"] != nil {
            return LastResult(kind: .skipped, text: nil, seconds: nil,
                              reason: obj["reason"] as? String ?? "沒有辨識到內容",
                              gate: gate, at: jsonAt)
        }
        if let text = obj["text"] as? String {
            return LastResult(kind: .ok, text: text,
                              seconds: obj["seconds"] as? Double,
                              reason: nil, gate: gate, at: jsonAt)
        }
        return nil
    }
}
