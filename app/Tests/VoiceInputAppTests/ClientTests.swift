import Foundation
import XCTest
@testable import VoiceInputApp

final class ResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url!.path == "/revoked" ? 401 : 200
        var response: [String: Any] = status == 401 ? ["error":"revoked"] :
            ["token": request.value(forHTTPHeaderField: "Authorization") ?? "",
             "spoof": request.value(forHTTPHeaderField: "X-Voice-User") ?? "",
             "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
             "threshold": request.value(forHTTPHeaderField: "X-Voice-Input-Thold") ?? ""]
        if request.url!.path == "/api/health" { response["whisper"] = true }
        if request.url!.path == "/api/pair/start" {
            let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? request.httpBodyStream!.readAll()) as! [String: Any]
            response = ["device_code":"synthetic-device-secret", "user_code":body["name"] as? String == "invalid" ? "bad#login=secret" : "ABCD2345"]
        }
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
    @MainActor
    func testPairingOpensAccountConfirmationWithoutSendingDeviceSecretToBrowser() async throws {
        let pairing = try await client().startPairing(name: "我的 Mac")
        XCTAssertEqual(pairing.verificationURL, "https://fixture.example/account#pair=ABCD2345")
        XCTAssertFalse(pairing.verificationURL.contains(pairing.deviceCode))
    }
    @MainActor
    func testMalformedPairingResponseCannotOpenAnUnrelatedBrowserAction() async {
        do { _ = try await client().startPairing(name: "invalid"); XCTFail("should reject malformed response") }
        catch SparkClient.Failure.message { }
        catch { XCTFail("wrong error") }
    }
}

private extension InputStream {
    func readAll() -> Data {
        open(); defer { close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true { let count = read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
        return result
    }
}
