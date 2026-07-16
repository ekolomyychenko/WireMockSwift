import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// In-process stub of the WireMock admin API, so the **client-side** logic of the
/// `expect(...)` layer — the `refine()` floor, `fetchSorted` ordering, terminals —
/// can be pinned WITHOUT a live server, and therefore killed by `muter` (which
/// runs the hermetic, server-less test command; see `.muter.conf.yml`).
///
/// A scoped `URLSession` routes every admin call through `StubURLProtocol`, which
/// replies from a per-endpoint FIFO queue of canned responses keyed by the base
/// URL's host (unique per transport, so parallel-safe by construction).
///
/// The synchronous transport keeps exactly one request in flight, so the queues
/// are consumed in call order — enqueue responses in the order the code will ask
/// for them (e.g. the base `toHaveBeenSent` count, then the refined `to*` count).
final class MockAdminTransport {
    struct CannedResponse {
        var status: Int
        var body: Data
    }

    // Registry keyed by host, guarded because URLProtocol runs on URLSession's
    // background delegate queue while the test thread blocks in the transport.
    private static let lock = NSLock()
    // Access is always guarded by `lock`, so the unsafe opt-out is sound.
    nonisolated(unsafe) private static var registry: [String: MockAdminTransport] = [:]

    let host: String
    private var queues: [String: [CannedResponse]] = [:]

    init() {
        // Alphanumeric host (a valid DNS label; URL lowercases the host).
        host = "t" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") + ".mock.local"
        Self.lock.lock(); Self.registry[host] = self; Self.lock.unlock()
    }

    deinit {
        Self.lock.lock(); Self.registry[host] = nil; Self.lock.unlock()
    }

    /// A `WireMock` client whose transport is this mock. Pass `reporter:` to
    /// observe the step seam (defaults to the production `NoopReporter`).
    func client(reporter: any WireMockReporter = NoopReporter()) -> WireMock {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WireMock(baseURL: URL(string: "http://\(host)")!, session: session, reporter: reporter)
    }

    // MARK: - Enqueue canned responses (endpoint = admin path after `/__admin/`)

    @discardableResult
    func enqueue(_ endpoint: String, status: Int = 200, json: String) -> Self {
        Self.lock.lock(); defer { Self.lock.unlock() }
        queues[endpoint, default: []].append(CannedResponse(status: status, body: Data(json.utf8)))
        return self
    }

    /// Next `POST /requests/count` returns this count.
    @discardableResult
    func enqueueCount(_ count: Int) -> Self {
        enqueue("requests/count", json: #"{"count": \#(count)}"#)
    }

    /// Next `POST /requests/find` returns these journal entries (raw JSON array).
    @discardableResult
    func enqueueFind(rawRequests json: String) -> Self {
        enqueue("requests/find", json: #"{"requests": \#(json)}"#)
    }

    /// Next `POST /near-misses/request-pattern` returns no near misses (keeps the
    /// shortfall error message bare and deterministic).
    @discardableResult
    func enqueueNoNearMisses() -> Self {
        enqueue("near-misses/request-pattern", json: #"{"nearMisses": []}"#)
    }

    // MARK: - Internals

    fileprivate static func router(forHost host: String) -> MockAdminTransport? {
        lock.lock(); defer { lock.unlock() }
        return registry[host]
    }

    /// Pops the next canned response for an endpoint, or nil if none was enqueued.
    fileprivate func next(for endpoint: String) -> CannedResponse? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard var queue = queues[endpoint], !queue.isEmpty else { return nil }
        let head = queue.removeFirst()
        queues[endpoint] = queue
        return head
    }
}

/// URLProtocol that answers admin calls from the `MockAdminTransport` registered
/// under the request's host. An unstubbed call gets a loud `501` so a missing
/// `enqueue` surfaces as a decode/status failure rather than a silent empty body.
final class StubURLProtocol: URLProtocol {
    // These override URLProtocol's class methods, so they must be `class func`
    // (you cannot `override static`) — the static_over_final_class rule misfires.
    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let prefix = "/__admin/"
        let endpoint = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path

        let canned = MockAdminTransport.router(forHost: host)?.next(for: endpoint)
            ?? MockAdminTransport.CannedResponse(status: 501, body: Data(#"{"error":"no stub for \#(endpoint)"}"#.utf8))

        let response = HTTPURLResponse(
            url: request.url!, statusCode: canned.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
