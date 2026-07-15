import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors surfaced by the WireMock admin client.
public enum WireMockError: Error, Sendable, CustomStringConvertible {
    /// The server returned a non-2xx status. Carries the status code and body.
    case unexpectedStatus(code: Int, body: String)
    /// The response body could not be decoded into the expected type.
    case decodingFailed(underlying: String)
    /// The configured base URL was invalid.
    case invalidBaseURL(String)
    /// A transport-level failure (connection refused, timeout, …).
    case transport(underlying: String)
    /// A count/verify/find was attempted while the server's request journal is
    /// disabled, so no request history is available.
    case requestJournalDisabled
    /// A client-side argument was rejected before any request was sent (e.g. an
    /// empty scenario/file name that would corrupt the request path).
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .unexpectedStatus(let code, let body):
            return "WireMock returned HTTP \(code): \(body)"
        case .decodingFailed(let underlying):
            return "Failed to decode WireMock response: \(underlying)"
        case .invalidBaseURL(let url):
            return "Invalid WireMock base URL: \(url)"
        case .transport(let underlying):
            return "WireMock transport error: \(underlying)"
        case .requestJournalDisabled:
            return "The WireMock request journal is disabled; request counts/history are unavailable"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        }
    }
}

/// Credentials for a WireMock admin API secured with `--admin-api-basic-auth`
/// (or a bearer/custom scheme). Applied as an `Authorization` header on every
/// admin request.
public enum AdminAuthorization: Sendable, CustomStringConvertible {
    case basic(username: String, password: String)
    case bearer(token: String)
    /// A raw `Authorization` header value, verbatim.
    case header(value: String)

    /// Masks the secret so credentials don't land in logs/reports; the username
    /// is shown for `basic`. (Change here if you ever want the raw value.)
    public var description: String {
        switch self {
        case .basic(let username, _): return "basic(username: \(username), password: ***)"
        case .bearer: return "bearer(token: ***)"
        case .header: return "header(value: ***)"
        }
    }

    var headerValue: String {
        switch self {
        case let .basic(username, password):
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case let .bearer(token):
            return "Bearer \(token)"
        case let .header(value):
            return value
        }
    }
}

/// Low-level synchronous HTTP client for the WireMock admin API (`/__admin/**`).
///
/// Handles URL building, JSON encoding/decoding and status-code checking.
/// Higher-level typed operations live on the `WireMock` facade.
public struct AdminClient: Sendable, CustomStringConvertible {
    public let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let authorization: AdminAuthorization?

    /// Whether an admin `Authorization` is configured (no secret exposed).
    public var isAuthorized: Bool { authorization != nil }

    public var description: String {
        "AdminClient(baseURL: \(baseURL.absoluteString), authorized: \(isAuthorized))"
    }

    /// - Parameters:
    ///   - baseURL: The server root, e.g. `http://localhost:8080`.
    ///   - session: URLSession to use (defaults to `.shared`). Inject a session
    ///     with a trust-evaluating delegate to reach an HTTPS server with a
    ///     self-signed certificate.
    ///   - timeout: Per-request timeout in seconds.
    ///   - authorization: Credentials for a secured admin API.
    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 30,
                authorization: AdminAuthorization? = nil) {
        // The synchronous transport blocks the calling thread until URLSession
        // delivers its completion on the session's delegate queue. A `delegateQueue:
        // .main` session invoked *from the main thread* could never deliver; `syncData`
        // detects exactly that case and throws a clear error rather than hanging.
        // `.shared` and `delegateQueue: nil` sessions deliver on a background queue
        // and are always safe.
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
        self.authorization = authorization
    }

    /// Escape hatch: performs a raw admin request against `/__admin/<path>` for
    /// any endpoint the typed API doesn't model, returning the response body.
    ///
    /// `path` is treated as already percent-encoded and sent verbatim; `body`, if
    /// given, is sent as-is with `contentType`. Non-2xx responses throw
    /// `.unexpectedStatus`, like every other admin call.
    @discardableResult
    public func rawRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) throws -> Data {
        try perform(method, path, query: query, body: body, contentType: contentType)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Bodyless request to `/__admin/<path>`, returning the raw response body.
    @discardableResult
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = []
    ) throws -> Data {
        try perform(method, path, query: query, body: nil)
    }

    /// Sends a raw body (e.g. a file's bytes) with an explicit content type.
    @discardableResult
    func sendData(
        _ method: String,
        _ path: String,
        body: Data?,
        contentType: String?
    ) throws -> Data {
        try perform(method, path, query: [], body: body, contentType: contentType)
    }

    /// Runs a request synchronously, blocking the calling thread until URLSession
    /// delivers the completion handler on the session's delegate queue. This is
    /// deadlock-free for the default `.shared` session (and any session created
    /// with `delegateQueue: nil`, which delivers on a background queue). A safety
    /// wait a bit past the request timeout guards against a stuck task.
    ///
    /// - Warning: a `URLSession` whose `delegateQueue` is `.main`, invoked from the
    ///   main thread, could never deliver its completion (the handler can't run while
    ///   this call blocks that thread). That exact case is detected up front and throws
    ///   `.transport` immediately, rather than hanging until the safety timeout. Inject
    ///   sessions with `delegateQueue: nil`.
    private func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        // Fail fast instead of deadlocking: if completion is delivered on the main
        // queue and we're about to block the main thread, the handler can never run.
        if session.delegateQueue === OperationQueue.main && Thread.isMainThread {
            throw WireMockError.transport(
                underlying: "URLSession delivers completions on delegateQueue: .main and this call is on "
                    + "the main thread — the synchronous transport would deadlock. Inject a URLSession "
                    + "created with delegateQueue: nil (it delivers on a background queue)."
            )
        }
        final class Holder: @unchecked Sendable { var result: Result<(Data, URLResponse), Error>? }
        let holder = Holder()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                holder.result = .failure(error)
            } else if let data, let response {
                holder.result = .success((data, response))
            } else {
                holder.result = .failure(WireMockError.transport(underlying: "No data and no error"))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 10) == .timedOut {
            task.cancel()
            throw WireMockError.transport(underlying: "Request timed out after \(timeout)s")
        }
        switch holder.result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        case nil: throw WireMockError.transport(underlying: "Request produced no result")
        }
    }

    /// Percent-encodes a single, user-supplied path segment (a scenario or file
    /// name) so it can't inject extra path segments (`/`) or bleed into the
    /// query/fragment (`?`, `#`). Rejects an empty segment, and `.`/`..`, up
    /// front rather than silently hitting the wrong endpoint (a bare `..` would
    /// traverse back out of the resource collection).
    static func pathSegment(_ raw: String) throws -> String {
        guard !raw.isEmpty else {
            throw WireMockError.invalidArgument("path segment must not be empty")
        }
        guard raw != "." && raw != ".." else {
            throw WireMockError.invalidArgument("path segment must not be '.' or '..'")
        }
        var allowed = CharacterSet.urlPathAllowed
        // `/` would split into segments; `?`/`#` would start the query/fragment.
        allowed.remove(charactersIn: "/?#")
        // urlPathAllowed maps every input, so the coalesce never actually fires.
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// Transport core: builds the URL, sends, checks the status code.
    ///
    /// `path` is treated as already percent-encoded: static callers pass ASCII-safe
    /// paths, and callers interpolating a user name pre-encode it via `pathSegment`.
    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String? = "application/json"
    ) throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WireMockError.invalidBaseURL(baseURL.absoluteString)
        }
        // Join the base URL's own path with `/__admin/<path>`, collapsing the
        // slashes at the seams. Assigning percentEncodedPath (rather than
        // appendingPathComponent) preserves pre-encoded segments verbatim — no
        // double-encoding of the `%` escapes produced by `pathSegment`.
        let base = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let tail = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.percentEncodedPath = "\(base)/__admin/\(tail)"
        if !query.isEmpty {
            // Encode query values ourselves: URLComponents leaves `+` literal, but
            // the server (Jetty) decodes query strings with form-urlencoded
            // semantics where `+` means space — so an ISO-8601 offset like
            // `since=...+01:00` would be misread. Escape `+` (and the other
            // sub-delimiters that must not appear raw in a value) via %-encoding.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=?#")
            components.percentEncodedQueryItems = query.map { item in
                URLQueryItem(
                    name: item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name,
                    value: item.value?.addingPercentEncoding(withAllowedCharacters: allowed)
                )
            }
        }
        guard let url = components.url else {
            throw WireMockError.invalidBaseURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let authorization {
            request.setValue(authorization.headerValue, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try syncData(for: request)
        } catch let error as WireMockError {
            throw error
        } catch {
            throw WireMockError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw WireMockError.transport(underlying: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WireMockError.unexpectedStatus(
                code: http.statusCode,
                body: Self.bodyText(data)
            )
        }
        return data
    }

    /// Renders a response body as text for error reporting. Falls back to
    /// ISO-8859-1 (which maps every byte) so a non-UTF8 or binary error body is
    /// never silently dropped to an empty string.
    private static func bodyText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// Sends an encodable body and decodes the response.
    func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        as: Response.Type
    ) throws -> Response {
        let payload = try Self.encoder.encode(body)
        let data = try perform(method, path, query: query, body: payload)
        return try decode(data)
    }

    /// Sends an encodable body, ignoring the response payload.
    func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body
    ) throws {
        let payload = try Self.encoder.encode(body)
        _ = try perform(method, path, query: query, body: payload)
    }

    /// Sends a bodyless request and decodes the response.
    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as: Response.Type
    ) throws -> Response {
        let data = try perform("GET", path, query: query, body: nil)
        return try decode(data)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            // Include the raw body so a server-shape surprise is diagnosable
            // (which key was missing *in what payload*), matching listFiles.
            throw WireMockError.decodingFailed(
                underlying: "\(error) — response body: \(Self.bodyText(data))"
            )
        }
    }
}
