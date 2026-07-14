import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hermetic unit tests for the client/transport layer, driven through a stubbed
/// `URLProtocol` — no WireMock server required. These cover paths that a live
/// server can't easily exercise: the `Authorization` header actually being
/// attached, the request-journal-disabled guard, and error-status surfacing.
final class ClientUnitTests: XCTestCase {

    private func makeClient(authorization: AdminAuthorization? = nil) -> WireMock {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return WireMock(baseURL: URL(string: "http://stub.local:8080")!,
                        authorization: authorization, session: session)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Authorization header attachment

    func testBasicAuthorizationHeaderIsAttached() async throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: .basic(username: "admin", password: "s3cret"))
        _ = try await client.getAllServeEvents()

        let sent = try XCTUnwrap(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let expected = "Basic " + Data("admin:s3cret".utf8).base64EncodedString()
        XCTAssertEqual(sent, expected, "the admin request must carry the Basic auth header")
    }

    func testBearerAuthorizationHeaderIsAttached() async throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: .bearer(token: "tok-123"))
        _ = try await client.getAllServeEvents()
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func testNoAuthorizationHeaderWhenUnconfigured() async throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: nil)
        _ = try await client.getAllServeEvents()
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Request journal disabled guard

    func testGetAllServeEventsThrowsWhenJournalDisabled() async throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[],"requestJournalDisabled":true}"#) }
        let client = makeClient()
        do {
            _ = try await client.getAllServeEvents()
            XCTFail("expected .requestJournalDisabled")
        } catch let error as WireMockError {
            guard case .requestJournalDisabled = error else {
                return XCTFail("expected .requestJournalDisabled, got \(error)")
            }
        }
    }

    func testCountRequestsThrowsWhenJournalDisabled() async throws {
        // Distinct DTO (CountResult) and HTTP verb (POST requests/count).
        MockURLProtocol.respond { _ in (200, #"{"count":-1,"requestJournalDisabled":true}"#) }
        let client = makeClient()
        do {
            _ = try await client.countRequests(matching: getRequestedFor(anyUrl).pattern)
            XCTFail("expected .requestJournalDisabled")
        } catch let error as WireMockError {
            guard case .requestJournalDisabled = error else {
                return XCTFail("expected .requestJournalDisabled, got \(error)")
            }
        }
    }

    func testCountRequestsReturnsCountWhenJournalEnabled() async throws {
        MockURLProtocol.respond { _ in (200, #"{"count":3}"#) }
        let client = makeClient()
        let count = try await client.countRequests(matching: getRequestedFor(anyUrl).pattern)
        XCTAssertEqual(count, 3)
    }

    // MARK: - Error status surfacing

    func testNon2xxSurfacesStatusAndBody() async throws {
        MockURLProtocol.respond { _ in (422, "the server said no") }
        let client = makeClient()
        do {
            _ = try await client.getAllServeEvents()
            XCTFail("expected .unexpectedStatus")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 422)
            XCTAssertEqual(body, "the server said no", "the raw error body must be surfaced verbatim")
        }
    }

    func testDecodingFailureSurfacesAsDecodingFailed() async throws {
        MockURLProtocol.respond { _ in (200, "not json at all") }
        let client = makeClient()
        do {
            _ = try await client.getAllServeEvents()
            XCTFail("expected .decodingFailed")
        } catch let error as WireMockError {
            guard case .decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }
}

/// A `URLProtocol` that returns canned responses and records the last request.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func respond(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = handler
        self.lastRequest = nil
    }

    static func reset() {
        handler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        let (status, body) = MockURLProtocol.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
