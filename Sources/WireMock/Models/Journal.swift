import Foundation

/// A request as recorded in WireMock's request journal.
///
/// Field set follows WireMock's `LoggedRequest`. Unknown extra keys returned by
/// the server are ignored; less-common fields are optional.
public struct LoggedRequest: Codable, Sendable, Hashable {
    public var url: String?
    public var absoluteUrl: String?
    public var method: HTTPMethod?
    public var scheme: String?
    public var host: String?
    public var port: Int?
    public var clientIp: String?
    public var headers: [String: HeaderValue]?
    public var cookies: [String: String]?
    public var body: String?
    public var bodyAsBase64: String?
    public var loggedDate: Int?
    public var loggedDateString: String?
    public var queryParams: JSONValue?
    public var formParams: JSONValue?
    public var browserProxyRequest: Bool?
    public var protocolVersion: String?

    private enum CodingKeys: String, CodingKey {
        case url, absoluteUrl, method, scheme, host, port, clientIp, headers, cookies
        case body, bodyAsBase64, loggedDate, loggedDateString, queryParams, formParams
        case browserProxyRequest
        case protocolVersion = "protocol"
    }
}

/// A single serve event: a request plus how WireMock handled it.
public struct ServeEvent: Codable, Sendable, Hashable {
    public var id: UUID?
    public var request: LoggedRequest
    public var responseDefinition: ResponseDefinition?
    public var wasMatched: Bool?
    public var stubMapping: StubMapping?
}

/// How close an unmatched request came to a stub.
public struct MatchResult: Codable, Sendable, Hashable {
    public var distance: Double?
}

/// A "near miss" — a request that failed to match, with the closest stub and
/// its distance, for diagnostics.
public struct NearMiss: Codable, Sendable, Hashable {
    public var request: LoggedRequest?
    public var stubMapping: StubMapping?
    public var requestPattern: RequestPattern?
    public var matchResult: MatchResult?
}

// MARK: - Response envelopes

struct GetServeEventsResult: Decodable {
    let requests: [ServeEvent]
}

struct FindRequestsResult: Decodable {
    let requests: [LoggedRequest]
}

/// Envelope returned by `POST /__admin/requests/remove` (removed events).
struct RemovedServeEventsResult: Decodable {
    let serveEvents: [ServeEvent]
}

struct FindNearMissesResult: Decodable {
    let nearMisses: [NearMiss]
}
