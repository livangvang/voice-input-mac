import Foundation

@MainActor
struct SparkClient {
    let base: String
    var token: String? = nil
    var session: URLSession = productionSession
    private static let productionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    struct Health { let whisperReady: Bool; let threshold: Double? }
    enum Failure: LocalizedError {
        case message(String)
        case unauthorized
        var errorDescription: String? { if case let .message(s) = self { return s }; return "配對已失效，請重新配對" }
    }
    func request(_ path: String, json: [String: Any]? = nil, audio: Data? = nil, threshold: Double? = nil) async throws -> [String: Any] {
        guard let url = URL(string: base + path), url.scheme == "https", url.host != nil else {
            throw Failure.message("Spark 網址需要 HTTPS")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = audio == nil ? 12 : 100
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json { req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: json); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let audio {
            req.httpMethod = "POST"; req.httpBody = audio
            req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            req.setValue("mac", forHTTPHeaderField: "X-Voice-Input-Client")
            if let threshold { req.setValue(String(Int(threshold)), forHTTPHeaderField: "X-Voice-Input-Thold") }
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.message("伺服器回應格式不正確") }
        if http.statusCode == 401 { throw Failure.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw Failure.message(obj["error"] as? String ?? "伺服器暫時無法使用") }
        return obj
    }
    func health() async -> Health? {
        guard let obj = try? await request("/api/health") else { return nil }
        return Health(whisperReady: obj["whisper"] as? Bool ?? false, threshold: obj["threshold"] as? Double)
    }
    func history(limit: Int = 12) async -> [HistoryItem] {
        guard let obj = try? await request("/api/history"), let rows = obj["items"] as? [[String: Any]] else { return [] }
        return rows.prefix(limit).map { row in
            let ts = row["ts"] as? String ?? ""
            return HistoryItem(time: ts.count >= 16 ? String(ts.dropFirst(11).prefix(5)) : "", text: row["text"] as? String ?? "", fromWeb: (row["src"] as? String ?? "").hasPrefix("web"))
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
