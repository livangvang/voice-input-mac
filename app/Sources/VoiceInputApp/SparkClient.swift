import Foundation

/// Spark 的唯讀 API。
///
/// 只做 GET。錄音和上傳留在 voice-input-mac.sh——sox 必須在 shell 裡跑、WAV 也在
/// 那裡，而且那支腳本要能獨立運作。同一套邏輯寫兩份正是 README-mac.md 記載過的坑
/// （舊版 Mac 端繞過 API 直接打 whisper，結果閘門、校正表、歷史全部失效）。
struct SparkClient {
    let base: String

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // Tailscale 斷線時 DNS 會慢慢失敗。逾時設短一點，讓畫面早點說「連不上」，
        // 而不是讓使用者盯著一個沒有結論的轉圈。
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    struct Health {
        let whisperReady: Bool
        let threshold: Double?
    }

    func health() async -> Health? {
        guard let obj = await getJSON("/api/health") else { return nil }
        return Health(
            whisperReady: obj["whisper"] as? Bool ?? false,
            threshold: obj["threshold"] as? Double
        )
    }

    func history(limit: Int = 12) async -> [HistoryItem] {
        guard let obj = await getJSON("/api/history"),
              let items = obj["items"] as? [[String: Any]]
        else { return [] }

        return items.suffix(limit).reversed().map { it in
            let ts = it["ts"] as? String ?? ""
            // ts 是 ISO 8601，取 HH:mm 就好——這是「剛剛講了什麼」的清單，
            // 不是日誌，年月日在這裡沒有資訊量。
            let time = ts.count >= 16 ? String(Array(ts)[11..<16]) : ""
            return HistoryItem(
                time: time,
                text: it["text"] as? String ?? "",
                fromWeb: (it["src"] as? String ?? "").hasPrefix("web")
            )
        }
    }

    private func getJSON(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        do {
            let (data, resp) = try await Self.session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil   // 連不上就是連不上，呼叫端只需要知道 nil
        }
    }
}

private extension String {
    /// 從字元索引取子字串。ts 是固定格式的 ISO 8601，不必為此拉一個日期解析器。
    init(_ slice: ArraySlice<Character>) {
        self.init(String(slice.map { $0 }))
    }
}
