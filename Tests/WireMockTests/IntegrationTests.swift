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
/// docker run --rm -p 8080:8080 wiremock/wiremock:3
/// swift test
/// ```
final class IntegrationTests: XCTestCase {
    private var wireMock: WireMock!
    private var baseURL: URL!

    override func setUp() async throws {
        let urlString = ProcessInfo.processInfo.environment["WIREMOCK_URL"] ?? "http://localhost:8080"
        baseURL = URL(string: urlString)!
        wireMock = WireMock(baseURL: baseURL)

        // Skip the whole suite if no server is listening.
        do {
            _ = try await wireMock.listAllStubMappings()
        } catch {
            throw XCTSkip("No WireMock server reachable at \(urlString): \(error)")
        }
        try await wireMock.resetAll()
    }

    override func tearDown() async throws {
        if wireMock != nil {
            try? await wireMock.resetAll()
        }
    }

    /// The core round-trip: register a stub, hit it, verify it was recorded.
    func testStubHitAndVerify() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/hello"))
                .willReturn(okForJson(["message": "world"]))
        )

        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("hello")
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, ["message": "world"])

        let count = try await wireMock.countRequests(method: "GET", url: "/hello")
        XCTAssertEqual(count, 1)
    }

    func testHeaderMatchingStub() async throws {
        try await wireMock.stubFor(
            get(urlEqualTo("/secured"))
                .withHeader("Authorization", equalTo("Bearer token"))
                .willReturn(ok("granted"))
        )

        // Without the header -> not matched (404).
        let (_, missResponse) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("secured")
        )
        XCTAssertEqual((missResponse as? HTTPURLResponse)?.statusCode, 404)

        // With the header -> matched.
        var request = URLRequest(url: baseURL.appendingPathComponent("secured"))
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let (data, hitResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((hitResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "granted")
    }

    func testListAndRemoveMappings() async throws {
        let created = try await wireMock.stubFor(get(urlEqualTo("/temp")).willReturn(ok()))
        let id = try XCTUnwrap(created.id)

        var all = try await wireMock.listAllStubMappings()
        XCTAssertTrue(all.contains { $0.id == id })

        try await wireMock.removeStubMapping(id: id)
        all = try await wireMock.listAllStubMappings()
        XCTAssertFalse(all.contains { $0.id == id })
    }
}
