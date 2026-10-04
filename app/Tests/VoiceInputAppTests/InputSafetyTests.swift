import AppKit
import XCTest
@testable import VoiceInputApp

private actor DelayedCredentials: CredentialStorage {
    func load(server: String, allowInteraction: Bool) async throws -> String? { blockingRead() }
    private func blockingRead() -> String {
        precondition(!Thread.isMainThread)
        Thread.sleep(forTimeInterval: 0.3)
        return "synthetic-device-token"
    }
    func save(_ token: String, server: String) async throws {}
}

final class InputSafetyTests: XCTestCase {
    @MainActor
    func testOrdinaryKeysAndShortcutsAlwaysReachTheOriginalApp() throws {
        let hotkeys = NativeHotkeys()
        var actions: [String] = []
        hotkeys.action = { actions.append($0) }
        hotkeys.isRecording = { true }
        for (key, flags) in [(UInt16(0), NSEvent.ModifierFlags()), (53, []), (9, [.control, .option])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: key))
            XCTAssertTrue(hotkeys.observeLocal(event) === event)
        }
        XCTAssertEqual(actions, ["cancel", "toggle"])
    }

    @MainActor
    func testDelayedKeychainReadDoesNotBlockTypingOrUseAnotherServersToken() async throws {
        let credentials = CredentialCache(storage: DelayedCredentials())
        let started = ContinuousClock.now
        let loading = Task { try await credentials.load(server: "https://one.example", allowInteraction: false) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200), "The main actor must remain responsive during credential I/O")
        let before = ContinuousClock.now
        XCTAssertNil(credentials.token(for: "https://one.example"))
        XCTAssertLessThan(before.duration(to: .now), .milliseconds(50))
        try await loading.value
        XCTAssertEqual(credentials.token(for: "https://one.example"), "synthetic-device-token")
        XCTAssertNil(credentials.token(for: "https://two.example"))
        credentials.clear(server: "https://one.example")
        XCTAssertNil(credentials.token(for: "https://one.example"))
    }

    @MainActor
    func testQueuedShortcutAfterAStallDoesNotStartALateRecording() throws {
        let hotkeys = NativeHotkeys()
        var actions: [String] = []
        hotkeys.action = { actions.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option], timestamp: ProcessInfo.processInfo.systemUptime - 5,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 9))
        XCTAssertTrue(hotkeys.observeLocal(event) === event)
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testHealthCheckCompletesWhileAccountStorageIsStillWaiting() async throws {
        let credentials = CredentialCache(storage: DelayedCredentials())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseFixture.self]
        let network = SparkClient(base: "https://fixture.example", session: URLSession(configuration: config))
        let loading = Task { try await credentials.load(server: network.base, allowInteraction: false) }
        try await Task.sleep(for: .milliseconds(30))
        let health = await network.health()
        XCTAssertEqual(health?.whisperReady, true)
        XCTAssertNil(credentials.token(for: network.base), "Health must not depend on a completed Keychain read")
        let response = try await network.request("/api/health")
        XCTAssertEqual(response["token"] as? String, "", "Health does not send account credentials")
        try await loading.value
    }
}
