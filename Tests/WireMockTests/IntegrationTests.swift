import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end tests against a real WireMock server.
///
/// Skipped automatically unless a server is reachable. Point at one with the
/// `WIREMOCK_URL` env var (default `http://localhost:8080`), e.g.:
///
/// ```
/// docker run --rm -p 8080:8080 wiremock/wiremock:3.13.2
/// swift test
/// ```
final class IntegrationTests: XCTestCase {
    private var wireMock: WireMock!
    private var baseURL: URL!

    override func setUpWithError() throws {
        let urlString = ProcessInfo.processInfo.environment["WIREMOCK_URL"] ?? "http://localhost:8080"
        baseURL = URL(string: urlString)!
        wireMock = WireMock(baseURL: baseURL)

        // Skip the whole suite if no server is listening.
        do {
            _ = try wireMock.listAllStubMappings()
        } catch {
            throw XCTSkip("No WireMock server reachable at \(urlString): \(error)")
        }
        try wireMock.resetAll()
    }

    override func tearDownWithError() throws {
        if wireMock != nil {
            try? wireMock.resetAll()
        }
    }

    /// The core round-trip: register a stub, hit it, verify it was recorded.
    func testStubHitAndVerify() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/hello"))
                .willReturn(okForJson(["message": "world"]))
        )

        let (data, http) = try WireMockFixture.hit("hello")
        XCTAssertEqual(http.statusCode, 200)

        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, ["message": "world"])

        let count = try wireMock.countRequests(method: "GET", url: "/hello")
        XCTAssertEqual(count, 1)
    }

    func testHeaderMatchingStub() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/secured"))
                .withHeader("Authorization", equalTo("Bearer token"))
                .willReturn(ok("granted"))
        )

        // Without the header -> not matched (404).
        let (_, missHttp) = try WireMockFixture.hit("secured")
        XCTAssertEqual(missHttp.statusCode, 404)

        // With the header -> matched.
        let (data, hitHttp) = try WireMockFixture.hit("secured", headers: ["Authorization": "Bearer token"])
        XCTAssertEqual(hitHttp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "granted")
    }

    func testListAndRemoveMappings() throws {
        let created = try wireMock.stubFor(get(urlEqualTo("/temp")).willReturn(ok()))
        let id = try XCTUnwrap(created.id)

        var all = try wireMock.listAllStubMappings()
        XCTAssertTrue(all.contains { $0.id == id })

        try wireMock.removeStubMapping(id: id)
        all = try wireMock.listAllStubMappings()
        XCTAssertFalse(all.contains { $0.id == id })
    }
}
