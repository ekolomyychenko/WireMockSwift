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

    // MARK: - Custom query percent-encoding (the reason AdminClient hand-encodes)

    func testQueryValueEscapesPlusAndSubDelimiters() throws {
        // AdminClient encodes query values itself and drops `+&=?#` from the
        // allowed set, because Jetty reads `+` in a query as a space (which would
        // corrupt an ISO-8601 `since=...+01:00`). This asserts on the URL that
        // actually goes on the wire — a regression that removed the hand-encoding
        // would still return a valid-looking client value, so only the wire form
        // catches it. One value carries all four sub-delimiters at once.
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient()
        _ = try client.getServeEvents(since: "a+b&c=d#e")

        let url = try XCTUnwrap(MockURLProtocol.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("since=a%2Bb%26c%3Dd%23e"),
                      "query value must be percent-encoded on the wire, got: \(url)")
        XCTAssertFalse(url.contains("+"), "a raw + would be misread as a space by Jetty: \(url)")
    }

    func testIso8601OffsetSurvivesAsPercentEncodedPlus() throws {
        // The concrete case the hand-encoding exists for: a positive UTC offset.
        MockURLProtocol.respond { _ in (200, #"{"requests":[]}"#) }
        let client = makeClient()
        _ = try client.getServeEvents(since: "2024-01-01T00:00:00+01:00")

        let url = try XCTUnwrap(MockURLProtocol.lastRequest?.url?.absoluteString)
        XCTAssertTrue(url.contains("2024-01-01T00:00:00%2B01:00"),
                      "the +01:00 offset must reach the server as %2B, got: \(url)")
    }

    // MARK: - saveMappings persists via POST /__admin/mappings/save

    func testSaveMappingsPostsToSaveEndpoint() throws {
        MockURLProtocol.respond { _ in (200, "") }
        let client = makeClient()
        try client.saveMappings()

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/__admin/mappings/save")
    }

    // MARK: - Transport failure surfaces as .transport

    func testTransportFailureSurfacesAsTransport() throws {
        // A connection-level failure (no HTTP response at all) must be mapped to
        // WireMockError.transport, not leak the raw URLError to callers.
        MockURLProtocol.respondFailure(URLError(.cannotConnectToHost))
        let client = makeClient()
        XCTAssertThrowsError(try client.getAllServeEvents()) { error in
            guard case WireMockError.transport = error else {
                return XCTFail("expected .transport, got \(error)")
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
    nonisolated(unsafe) private static var _dataHandler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _lastRequest: URLRequest?
    nonisolated(unsafe) private static var _lastBody: Data?
    nonisolated(unsafe) private static var _failure: URLError?

    static func respond(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
        _dataHandler = nil
        _failure = nil
        _lastRequest = nil
        _lastBody = nil
    }

    /// Like `respond`, but returns raw bytes — so a test can emit a **non-UTF8**
    /// or binary response body (which the `String`-based `respond` can't express).
    static func respondData(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        _dataHandler = handler
        _handler = nil
        _failure = nil
        _lastRequest = nil
        _lastBody = nil
    }

    /// Makes the next load fail at the transport level (connection refused,
    /// timeout, …) so the client's `.transport` mapping can be exercised
    /// without a real unreachable socket.
    static func respondFailure(_ error: URLError) {
        lock.lock(); defer { lock.unlock() }
        _failure = error
        _handler = nil
        _lastRequest = nil
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _dataHandler = nil
        _failure = nil
        _lastRequest = nil
        _lastBody = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequest
    }

    /// The body bytes of the last intercepted request. URLSession moves `httpBody`
    /// into `httpBodyStream` before the protocol sees it, so we read the stream —
    /// letting a test assert the client sent exactly the bytes it was given.
    static var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return _lastBody
    }

    private static func capturedBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // URLProtocol requires these as overridable class methods; `static` would not
    // override the superclass, so the mock would never intercept requests.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol._lastRequest = request
        MockURLProtocol._lastBody = MockURLProtocol.capturedBody(of: request)
        let handler = MockURLProtocol._handler
        let dataHandler = MockURLProtocol._dataHandler
        let failure = MockURLProtocol._failure
        MockURLProtocol.lock.unlock()

        // Simulate a transport-level failure (no HTTP response at all).
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        // If the session was torn down / both handlers cleared, fail the load
        // cleanly instead of force-unwrapping on a background thread.
        guard let url = request.url, handler != nil || dataHandler != nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let status: Int
        let bodyData: Data
        if let dataHandler {
            (status, bodyData) = dataHandler(request)
        } else {
            let (code, body) = handler!(request)
            (status, bodyData) = (code, Data(body.utf8))
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bodyData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
