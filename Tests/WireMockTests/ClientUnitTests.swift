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

    private var session: URLSession?

    private func makeClient(authorization: AdminAuthorization? = nil) -> WireMock {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        self.session = session
        return WireMock(baseURL: URL(string: "http://stub.local:8080")!,
                        authorization: authorization, session: session)
    }

    override func tearDown() {
        // Deterministically tear the session down so no URLProtocol callback
        // fires on a background thread after the test ends.
        session?.invalidateAndCancel()
        session = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Failable scheme/host/port initializer

    func testInitSchemeHostPortBuildsExpectedBaseURL() throws {
        let client = try XCTUnwrap(WireMock(scheme: "https", host: "example.com", port: 9000))
        XCTAssertEqual(client.admin.baseURL.absoluteString, "https://example.com:9000")
    }

    func testInitReturnsNilForMalformedHost() {
        // A host with a space can't form a valid URL, so the failable init must
        // return nil rather than trap (host/port often come from config/env).
        XCTAssertNil(WireMock(scheme: "http", host: "bad host", port: 8080))
    }

    // MARK: - listFiles decodes both the bare-array and {files:[...]} shapes

    func testListFilesDecodesWrapperObjectShape() throws {
        MockURLProtocol.respond { _ in (200, #"{"files":["a.json","b.json"]}"#) }
        let client = makeClient()
        XCTAssertEqual(try client.listFiles(), ["a.json", "b.json"])
    }

    // MARK: - Authorization header attachment

    func testBasicAuthorizationHeaderIsAttached() throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: .basic(username: "admin", password: "s3cret"))
        _ = try client.getAllServeEvents()

        let sent = try XCTUnwrap(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let expected = "Basic " + Data("admin:s3cret".utf8).base64EncodedString()
        XCTAssertEqual(sent, expected, "the admin request must carry the Basic auth header")
    }

    func testBearerAuthorizationHeaderIsAttached() throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: .bearer(token: "tok-123"))
        _ = try client.getAllServeEvents()
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func testNoAuthorizationHeaderWhenUnconfigured() throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient(authorization: nil)
        _ = try client.getAllServeEvents()
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Request journal disabled guard

    func testGetAllServeEventsThrowsWhenJournalDisabled() throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[],"requestJournalDisabled":true}"#) }
        let client = makeClient()
        do {
            _ = try client.getAllServeEvents()
            XCTFail("expected .requestJournalDisabled")
        } catch let error as WireMockError {
            guard case .requestJournalDisabled = error else {
                return XCTFail("expected .requestJournalDisabled, got \(error)")
            }
        }
    }

    func testCountRequestsThrowsWhenJournalDisabled() throws {
        // Distinct DTO (CountResult) and HTTP verb (POST requests/count).
        MockURLProtocol.respond { _ in (200, #"{"count":-1,"requestJournalDisabled":true}"#) }
        let client = makeClient()
        do {
            _ = try client.countRequests(matching: getRequestedFor(anyUrl).pattern)
            XCTFail("expected .requestJournalDisabled")
        } catch let error as WireMockError {
            guard case .requestJournalDisabled = error else {
                return XCTFail("expected .requestJournalDisabled, got \(error)")
            }
        }
    }

    func testGetUnmatchedRequestsThrowsWhenJournalDisabled() throws {
        // Must throw like the sibling journal methods, not silently return [].
        MockURLProtocol.respond { _ in (200, #"{"requests":[],"requestJournalDisabled":true}"#) }
        let client = makeClient()
        XCTAssertThrowsError(try client.getUnmatchedRequests()) { error in
            guard case WireMockError.requestJournalDisabled = error else {
                return XCTFail("expected .requestJournalDisabled, got \(error)")
            }
        }
    }

    func testCountRequestsReturnsCountWhenJournalEnabled() throws {
        MockURLProtocol.respond { _ in (200, #"{"count":3}"#) }
        let client = makeClient()
        let count = try client.countRequests(matching: getRequestedFor(anyUrl).pattern)
        XCTAssertEqual(count, 3)
    }

    // MARK: - Error status surfacing

    func testNon2xxSurfacesStatusAndBody() throws {
        MockURLProtocol.respond { _ in (422, "the server said no") }
        let client = makeClient()
        do {
            _ = try client.getAllServeEvents()
            XCTFail("expected .unexpectedStatus")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 422)
            XCTAssertEqual(body, "the server said no", "the raw error body must be surfaced verbatim")
        }
    }

    func testDecodingFailureSurfacesAsDecodingFailed() throws {
        MockURLProtocol.respond { _ in (200, "not json at all") }
        let client = makeClient()
        do {
            _ = try client.getAllServeEvents()
            XCTFail("expected .decodingFailed")
        } catch let error as WireMockError {
            guard case .decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }
}

/// A `URLProtocol` that returns canned responses and records the last request.
/// Static state is lock-guarded because `URLProtocol` callbacks run on the
/// session's own queue, not the test thread.
final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var _lastRequest: URLRequest?

    static func respond(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
        _lastRequest = nil
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _lastRequest = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol._lastRequest = request
        let handler = MockURLProtocol._handler
        MockURLProtocol.lock.unlock()

        // If the session was torn down / handler cleared, fail the load cleanly
        // instead of force-unwrapping on a background thread.
        guard let url = request.url, let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let (status, body) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
