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
    // Port is not hardcoded: override via the WIREMOCK_URL env var (e.g. set it
    // in your .xctestplan). Defaults to 8080 only as a convenience.
    private var base: String {
        ProcessInfo.processInfo.environment["WIREMOCK_URL"] ?? "http://localhost:8080"
    }

    func testAppRendersStubbedResponse() async throws {
        let wireMock = WireMock(baseURL: URL(string: base)!)

        // The UI-test process itself talks to WireMock from the simulator.
        do {
            _ = try await wireMock.listAllStubMappings()
        } catch {
            // In CI we pass TEST_RUNNER_WIREMOCK_REQUIRED=1 so an unreachable
            // server FAILS instead of skipping — otherwise this job, whose whole
            // purpose is to exercise the simulator↔host boundary, would go green
            // without ever proving anything.
            if ProcessInfo.processInfo.environment["WIREMOCK_REQUIRED"] == "1" {
                XCTFail("WIREMOCK_REQUIRED=1 but no WireMock reachable from the simulator at \(base): \(error)")
                throw error
            }
            throw XCTSkip("No WireMock server reachable from the simulator at \(base): \(error)")
        }
        try await wireMock.resetAll()
        try await wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        // Launch the app pointed at the same server.
        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = base
        app.launch()

        // The app fetched /ping and rendered the stubbed body.
        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let becomesPong = expectation(for: NSPredicate(format: "label == %@", "pong"), evaluatedWith: label)
        await fulfillment(of: [becomesPong], timeout: 10)

        // Verify (from the simulator) that the app actually reached WireMock.
        try await wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }
}
