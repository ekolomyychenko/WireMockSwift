import XCTest
import WireMock

/// Proves WireMockSwift works from an XCUITest running on the iOS Simulator:
/// the test runner (on the simulator) configures a stub via the WireMock client
/// over localhost → host jar, the app under test (also on the simulator) hits
/// the same host jar, and we verify the request — all cross the simulator↔host
/// network boundary, which plain `swift test` on macOS never exercises.
///
/// Requires a WireMock server running on the HOST at localhost:8080
/// (e.g. `java -jar wiremock-standalone-3.13.2.jar --port 8080`).
final class SampleAppUITests: XCTestCase {
    // Port is not hardcoded: override via the WIREMOCK_URL env var. Locally you can
    // export it before `xcodebuild test`; in CI it's forwarded to the runner as
    // TEST_RUNNER_WIREMOCK_URL (Xcode strips the prefix). Defaults to 8080.
    private var base: String {
        ProcessInfo.processInfo.environment["WIREMOCK_URL"] ?? "http://localhost:8080"
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup so a second test never inherits this one's stub/journal.
        // If the server was never reachable (skipped run) this simply no-ops.
        let wireMock = WireMock(admin: AdminClient(baseURL: URL(string: base)!, timeout: 8))
        try? wireMock.resetAll()
    }

    /// Connects across the simulator↔host boundary, retrying while the localhost
    /// path warms up, and enforces the fail-not-skip policy. Returns a live client,
    /// or throws XCTSkip / fails per `WIREMOCK_REQUIRED`.
    private func connect() throws -> WireMock {
        // Guard the anti-false-green wiring itself. In CI we forward TEST_RUNNER_CI
        // (→ CI) alongside TEST_RUNNER_WIREMOCK_REQUIRED (→ WIREMOCK_REQUIRED). If the
        // runner sees CI but NOT WIREMOCK_REQUIRED, the required-flag forwarding rotted
        // (renamed/typo'd/removed) — fail loudly now, otherwise the next transient
        // outage would XCTSkip the job green, defeating this job's entire purpose.
        // (Caveat: if the TEST_RUNNER_ mechanism breaks wholesale, both vanish and this
        // can't fire — it catches the realistic "someone dropped WIREMOCK_REQUIRED" case.)
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil {
            XCTAssertEqual(env["WIREMOCK_REQUIRED"], "1",
                "Running under CI but WIREMOCK_REQUIRED != 1 — the TEST_RUNNER_ env "
                + "forwarding is broken; the fail-not-skip guard would silently rot.")
        }

        // Short per-request timeout so the retries below stay quick. The
        // simulator↔host localhost path is occasionally slow to come up on CI, so
        // retry a few times before deciding it's genuinely unreachable.
        let wireMock = WireMock(admin: AdminClient(baseURL: URL(string: base)!, timeout: 8))
        var lastError: Error?
        for attempt in 1...5 {
            do {
                _ = try wireMock.listAllStubMappings()
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < 5 { Thread.sleep(forTimeInterval: 2) }
            }
        }
        if let lastError {
            if env["WIREMOCK_REQUIRED"] == "1" {
                XCTFail("WIREMOCK_REQUIRED=1 but no WireMock reachable from the simulator "
                    + "at \(base) after 5 tries: \(lastError)")
                throw lastError
            }
            throw XCTSkip("No WireMock server reachable from the simulator at \(base): \(lastError)")
        }
        return wireMock
    }

    /// Launches the app pointed at the same server and waits for its `result` label
    /// to reach `expected`. On failure, surfaces the label's ACTUAL value (which
    /// already holds the root cause — `error:…` / `http-NNN` / `no-url` / `loading`)
    /// and attaches a screenshot, so a CI/Allure flake is triageable instead of a
    /// bare "exceeded timeout".
    ///
    /// Note the app's `/ping` fetch uses `URLSession.shared`'s 60s default timeout
    /// while we wait 10s here; on a warm localhost path the request is sub-second,
    /// so the tighter wait is intentional (a real 10–60s stall is a genuine failure
    /// we want to see, now with the label value to explain it).
    @discardableResult
    private func launchAndExpect(label expected: String, timeout: TimeInterval = 10,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = base
        app.launch()

        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: timeout), "result label never appeared",
                      file: file, line: line)

        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: label)
        if XCTWaiter().wait(for: [exp], timeout: timeout) != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "result-label-on-failure"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("expected result label \"\(expected)\", got \"\(label.label)\"",
                    file: file, line: line)
        }
        return label
    }

    /// Happy path: the app renders the stubbed 200 body, proving the full
    /// simulator→host round-trip through the WireMock client.
    func testAppRendersStubbedResponse() throws {
        let wireMock = try connect()
        try wireMock.resetAll()
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        launchAndExpect(label: "pong")

        // Verify (from the simulator) that the app actually reached WireMock.
        try wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }

    /// Negative path: a non-200 stub must make the app render `http-500`. This proves
    /// the harness can go RED for the right reason — a hardcoded `"pong"` app or a
    /// no-op `verify` would pass the happy-path test but fail here — and that a real
    /// status code round-trips across the simulator↔host boundary.
    func testAppShowsHTTPErrorForNon200() throws {
        let wireMock = try connect()
        try wireMock.resetAll()
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(aResponse().withStatus(500)))

        launchAndExpect(label: "http-500")

        try wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }
}
