import Foundation
import XCTest
@testable import VoiceInputApp

private final class ResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url!.path == "/revoked" ? 401 : 200
        let response: [String: Any] = status == 401 ? ["error":"revoked"] :
            ["token": request.value(forHTTPHeaderField: "Authorization") ?? "",
             "spoof": request.value(forHTTPHeaderField: "X-Voice-User") ?? "",
             "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
             "threshold": request.value(forHTTPHeaderField: "X-Voice-Input-Thold") ?? ""]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    @MainActor
    private func client() -> SparkClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseFixture.self]
        return SparkClient(base: "https://fixture.example", token: "synthetic-token", session: URLSession(configuration: config))
    }
    @MainActor
    func testUploadUsesDeviceCredentialAndAudioHeaders() async throws {
        let result = try await client().request("/api/transcribe", audio: Data([0,1,2]), threshold: 1200)
        XCTAssertEqual(result["token"] as? String, "Bearer synthetic-token")
        XCTAssertEqual(result["spoof"] as? String, "")
        XCTAssertEqual(result["contentType"] as? String, "audio/wav")
        XCTAssertEqual(result["threshold"] as? String, "1200")
    }
    @MainActor
    func testRevokedDeviceProducesSpecificRecoveryError() async {
        do { _ = try await client().request("/revoked"); XCTFail("should fail") }
        catch SparkClient.Failure.unauthorized { }
        catch { XCTFail("wrong error") }
    }
    @MainActor
    func testPlainHttpCannotSendCredentials() async {
        var c = client(); c = SparkClient(base: "http://fixture.example", token: c.token, session: c.session)
        do { _ = try await c.request("/api/me"); XCTFail("should reject HTTP") }
        catch SparkClient.Failure.message(let message) { XCTAssertTrue(message.contains("HTTPS")) }
        catch { XCTFail("wrong error") }
    }
}
