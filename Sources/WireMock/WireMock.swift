import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The main entry point: a configured client for a running WireMock server.
///
/// Mirrors the Java `WireMock` client. Create one pointed at your server and
/// call `stubFor`, `verify`, `reset`, etc.
///
/// ```swift
/// let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)
/// try wireMock.stubFor(get(urlEqualTo("/hello")).willReturn(ok("world")))
/// ```
///
/// The `init?(scheme:host:port:)` convenience is failable — it returns `nil`
/// on a malformed host/port rather than trapping.
public struct WireMock: Sendable, CustomStringConvertible {
    /// The underlying admin API client.
    public let admin: AdminClient

    public var description: String {
        "WireMock(baseURL: \(admin.baseURL.absoluteString), authorized: \(admin.isAuthorized))"
    }

    /// Creates a client over a pre-built admin API client.
    public init(admin: AdminClient) {
        self.admin = admin
    }

    /// Creates a client for a server addressed by scheme/host/port.
    ///
    /// Returns `nil` if the scheme/host/port don't form a valid URL (e.g. an
    /// empty or malformed host from config/env) rather than trapping — host and
    /// port often come from runtime configuration. Use `init(baseURL:)` for full
    /// control.
    ///
    /// - Parameters:
    ///   - scheme: `http` or `https`.
    ///   - host: Server host.
    ///   - port: Server port.
    ///   - authorization: Credentials for a secured admin API (`--admin-api-basic-auth`).
    ///   - session: A custom `URLSession` (e.g. with a trust delegate for a self-signed HTTPS cert).
    public init?(scheme: String = "http", host: String = "localhost", port: Int = 8080,
                 authorization: AdminAuthorization? = nil, session: URLSession = .shared) {
        // Reject out-of-range ports and blank hosts up front. URLComponents is
        // lenient (a negative port or whitespace host can still yield a URL that
        // only fails later at transport), so validate rather than trap or defer.
        guard (1...65_535).contains(port),
              !host.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        guard let url = components.url else { return nil }
        self.admin = AdminClient(baseURL: url, session: session, authorization: authorization)
    }

    /// Creates a client for a server at the given base URL (e.g. a remote host).
    ///
    /// - Parameters:
    ///   - baseURL: The server root. Do **not** embed credentials as
    ///     `https://user:pass@host` — URLSession won't send them and they can
    ///     leak into error text; pass `authorization:` instead.
    ///   - authorization: Credentials for a secured admin API.
    ///   - session: A custom `URLSession` (e.g. with a trust delegate for a self-signed HTTPS cert).
    public init(baseURL: URL, authorization: AdminAuthorization? = nil, session: URLSession = .shared) {
        self.admin = AdminClient(baseURL: baseURL, session: session, authorization: authorization)
    }

    // MARK: - Stubbing

    /// Registers a stub from a builder and returns the persisted mapping
    /// (with the server-assigned id).
    @discardableResult
    public func stubFor(_ builder: MappingBuilder) throws -> StubMapping {
        try register(builder.build())
    }

    /// Registers a raw stub mapping.
    @discardableResult
    public func register(_ mapping: StubMapping) throws -> StubMapping {
        try admin.send("POST", "mappings", body: mapping, as: StubMapping.self)
    }

    /// Escape hatch: registers a stub from a structured JSON value, for any
    /// server feature not yet modelled by the typed DSL.
    public func register(json: JSONValue) throws {
        try admin.send("POST", "mappings", body: json)
    }

    /// Escape hatch: registers a stub from a raw JSON string.
    ///
    /// The string is validated as JSON up front (so malformed input fails here,
    /// not as an opaque server error) and then sent **verbatim** — a "raw" hatch
    /// must not reorder keys or coerce numbers, which a parse-and-re-encode round
    /// trip through `JSONValue` would.
    public func register(raw json: String) throws {
        let data = Data(json.utf8)
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw WireMockError.decodingFailed(underlying: "register(raw:) was given invalid JSON")
        }
        try admin.sendData("POST", "mappings", body: data, contentType: "application/json")
    }

    /// Lists all registered stub mappings.
    public func listAllStubMappings() throws -> [StubMapping] {
        try admin.get("mappings", as: ListStubMappingsResult.self).mappings
    }

    /// Fetches a single stub mapping by id.
    public func getStubMapping(id: UUID) throws -> StubMapping {
        try admin.get("mappings/\(id.uuidString)", as: StubMapping.self)
    }

    /// Updates an existing stub mapping in place.
    ///
    /// - Important: this PUTs exactly the `mapping` you pass. `StubMapping` only
    ///   models the fields this library knows about, so a fetch-modify-PUT of a
    ///   mapping created by a newer/other client may drop fields it doesn't model.
    ///   Build the mapping you intend to persist rather than round-tripping an
    ///   unknown one.
    @discardableResult
    public func editStubMapping(id: UUID, _ mapping: StubMapping) throws -> StubMapping {
        try admin.send("PUT", "mappings/\(id.uuidString)", body: mapping, as: StubMapping.self)
    }

    /// Removes a single stub mapping by id.
    public func removeStubMapping(id: UUID) throws {
        try admin.send("DELETE", "mappings/\(id.uuidString)")
    }

    /// Removes the stub matching the given builder (`POST /mappings/remove`),
    /// without needing to know its id (`removeStub(MappingBuilder)` in Java).
    public func removeStub(_ builder: MappingBuilder) throws {
        try admin.send("POST", "mappings/remove", body: builder.build())
    }

    /// Deletes all stub mappings.
    public func removeAllMappings() throws {
        try admin.send("DELETE", "mappings")
    }

    /// Persists the current in-memory stubs to the `mappings/` directory.
    public func saveMappings() throws {
        try admin.send("POST", "mappings/save")
    }

    /// Resets stub mappings to the baseline loaded from disk.
    public func resetToDefaultMappings() throws {
        try admin.send("POST", "mappings/reset")
    }

    // MARK: - Reset

    /// Resets everything: stubs, the request journal, and scenarios.
    public func resetAll() throws {
        try admin.send("POST", "reset")
    }

    // MARK: - Verification (basic)

    /// Counts journalled requests matching the given pattern.
    public func countRequests(matching pattern: RequestPattern) throws -> Int {
        let result = try admin.send("POST", "requests/count", body: pattern, as: CountResult.self)
        // The server returns count == -1 with this flag when the journal is off;
        // surface a clear error rather than a bogus negative count.
        if result.requestJournalDisabled == true { throw WireMockError.requestJournalDisabled }
        return result.count
    }

    /// Convenience: count requests received for a method + exact URL.
    public func countRequests(method: HTTPMethod, url: String) throws -> Int {
        try countRequests(matching: RequestPattern(method: method, url: url))
    }

    // MARK: - Lifecycle

    /// Requests the server shut down.
    public func shutdownServer() throws {
        try admin.send("POST", "shutdown")
    }
}
