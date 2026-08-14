import Foundation

/// 錄音狀態機。跟 .sh 寫進 $TMPDIR/voice-input/phase 的三個值一一對應。
enum Phase: String {
    case idle
    case recording
    case transcribing

    var label: String {
        switch self {
        case .idle: return "待命"
        case .recording: return "收音中"
        case .transcribing: return "辨識中"
        }
    }
}

/// 能量閘門的統計。speech-gate.py 印到 stderr 的那行人類可讀字串解析而來。
///
/// 那個字串**從來就不是設計成 API 的**，所以一定要保留 `raw`：
/// 格式哪天改了，畫面要退化成「還看得懂」，不是變成空白。
struct Gate {
    let raw: String
    let p95: Double?
    let median: Double?
    let floor: Double?
    let ratio: Double?
    let needP95: Double?
    let needRatio: Double?

    /// 這次到底有沒有過門檻。兩個條件都要過，跟伺服器端同一套判準。
    var passed: Bool? {
        guard let p95, let needP95, let ratio, let needRatio else { return nil }
        return p95 >= needP95 && ratio >= needRatio
    }

    init?(_ s: String?) {
        guard let s, !s.isEmpty else { return nil }
        raw = s
        p95 = Gate.number(in: s, pattern: #"p95=(\d+)"#)
        median = Gate.number(in: s, pattern: #"median=(\d+)"#)
        floor = Gate.number(in: s, pattern: #"floor=(\d+)"#)
        ratio = Gate.number(in: s, pattern: #"ratio=([\d.]+)"#)
        needP95 = Gate.number(in: s, pattern: #"p95>=(\d+)"#)
        needRatio = Gate.number(in: s, pattern: #"ratio>=([\d.]+)"#)
    }

    private static func number(in s: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return Double(s[r])
    }
}

/// 最後一次辨識的結果。
struct LastResult {
    enum Kind {
        case ok          // 辨識成功
        case skipped     // 被能量閘門擋下
        case error       // 伺服器回報錯誤
        case note        // 伺服器不知道的本地狀況（連不上、錄音太短）
    }

    let kind: Kind
    let text: String?
    let seconds: Double?
    let reason: String?
    let gate: Gate?
    let at: Date
}

/// App 畫面上的全部狀態。一次算好整包再換上去，避免各欄位來自不同時間點。
struct AppStatus {
    var phase: Phase = .idle
    var recordingSince: Date?
    var last: LastResult?

    var hammerspoonRunning = false
    var accessibilityGranted: Bool?   // nil = 問不到（Hammerspoon 沒在跑）

    var serverReachable: Bool?        // nil = 還沒測
    var whisperReady: Bool?
    var threshold: Double?
    var serverCheckedAt: Date?

    var history: [HistoryItem] = []

    /// 熱鍵現在到底有沒有用。這是整個 App 最重要的一句話——
    /// Hammerspoon 沒在跑或沒拿到輔助使用權限，連按兩下 Ctrl 就是完全沒反應，
    /// 而這兩種情況在選單列上都看不出來（圖示本身就是 Hammerspoon 畫的）。
    var hotkeyWorking: Bool {
        hammerspoonRunning && (accessibilityGranted ?? false)
    }

    var elapsed: TimeInterval? {
        guard phase == .recording, let recordingSince else { return nil }
        return Date().timeIntervalSince(recordingSince)
    }
}

struct HistoryItem: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let fromWeb: Bool
}
