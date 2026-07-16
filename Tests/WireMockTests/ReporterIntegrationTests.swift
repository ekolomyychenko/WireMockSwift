import XCTest
@testable import WireMock

/// Live end-to-end check of the reporter seam against a real WireMock server: the
/// shipped `XCTActivityReporter` wraps `stubFor` / `verify` / `expect` in real
/// `XCTContext.runActivity` steps while driving actual HTTP, without crashing and
/// while staying behaviour-transparent. `XCTSkip`s when no server is reachable.
///
/// The steps this emits (`Stub: …`, `Verify (…): …`, `Capture request: …`, each
/// with a WireMock-JSON attachment) are what an `.xcresult` inspection confirms
/// land as Allure/Xcode report steps — the one thing not observable server-less.
/// `Scripts/verify-reporter-xcresult.sh` drives THIS test through xcodebuild and
/// asserts those attachments landed in the result bundle (CI job "Reporter .xcresult
/// guard").
final class ReporterIntegrationTests: XCTestCase {

    func testReporterEmitsStepsWhileDrivingLiveServer() throws {
        // Reset the shared server (or skip if none reachable), then talk to it
        // through a reporter-enabled client.
        _ = try WireMockFixture.clientOrSkip()
        let wireMock = WireMock(baseURL: WireMockFixture.baseURL, reporter: XCTActivityReporter())

        try wireMock.stubFor(get(urlEqualTo("/reporter-demo")).willReturn(ok("hi")))

        let (_, response) = try WireMockFixture.hit("reporter-demo")
        XCTAssertEqual(response.statusCode, 200)

        try wireMock.verify(getRequestedFor(urlEqualTo("/reporter-demo")))

        let captured = try wireMock.expect(getRequestedFor(urlEqualTo("/reporter-demo"))).single()
        XCTAssertEqual(captured.url, "/reporter-demo")
    }
}
