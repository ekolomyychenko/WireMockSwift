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
        }
    }
}

/// Low-level async HTTP client for the WireMock admin API (`/__admin/**`).
///
/// Handles URL building, JSON encoding/decoding and status-code checking.
/// Higher-level typed operations live on the `WireMock` facade.
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
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
        self.authorization = authorization
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// Bodyless request to `/__admin/<path>`, returning the raw response body.
    @discardableResult
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        try await perform(method, path, query: query, body: nil)
    }

    /// Sends a raw body (e.g. a file's bytes) with an explicit content type.
    @discardableResult
    func sendData(
        _ method: String,
        _ path: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        try await perform(method, path, query: [], body: body, contentType: contentType)
    }

    /// Transport core: builds the URL, sends, checks the status code.
    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String? = "application/json"
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("__admin").appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw WireMockError.invalidBaseURL(baseURL.absoluteString)
        }
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
            (data, response) = try await session.data(for: request)
        } catch {
            // Preserve cancellation as cancellation rather than mislabelling it
            // a transport failure (loses the type for cancelled callers).
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw WireMockError.transport(underlying: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw WireMockError.transport(underlying: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WireMockError.unexpectedStatus(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    /// Sends an encodable body and decodes the response.
    func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        as: Response.Type
    ) async throws -> Response {
        let payload = try Self.encoder.encode(body)
        let data = try await perform(method, path, query: query, body: payload)
        return try decode(data)
    }

    /// Sends an encodable body, ignoring the response payload.
    func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body
    ) async throws {
        let payload = try Self.encoder.encode(body)
        _ = try await perform(method, path, query: query, body: payload)
    }

    /// Sends a bodyless request and decodes the response.
    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as: Response.Type
    ) async throws -> Response {
        let data = try await perform("GET", path, query: query, body: nil)
        return try decode(data)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw WireMockError.decodingFailed(underlying: String(describing: error))
        }
    }
}
