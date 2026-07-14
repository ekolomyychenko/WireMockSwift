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
    /// A cookie may carry one value or several (repeated `Cookie` entries),
    /// so this reuses the string-or-array `HeaderValue` shape rather than a
    /// plain `[String: String]`, which would fail to decode the array form.
    public var cookies: [String: HeaderValue]?
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

/// The response WireMock actually sent for a serve event (after rendering the
/// `responseDefinition` — proxying, templating, etc. already applied).
public struct LoggedResponse: Codable, Sendable, Hashable {
    public var status: Int?
    public var headers: [String: HeaderValue]?
    public var body: String?
    public var bodyAsBase64: String?
    public var fault: Fault?
}

/// Per-request latency breakdown (milliseconds) attached to a serve event.
public struct Timing: Codable, Sendable, Hashable {
    public var addedDelay: Int?
    public var processTime: Int?
    public var responseSendTime: Int?
    public var serveTime: Int?
    public var totalTime: Int?
}

/// A diagnostic sub-event attached to a serve event or match result (e.g. a
/// `REQUEST_NOT_MATCHED` diff report). Mirrors WireMock's `SubEvent`; `data` is
/// free-form JSON (the server puts a diff/near-miss report here).
public struct SubEvent: Codable, Sendable, Hashable {
    public var type: String?
    public var timeOffsetNanos: Int?
    public var data: JSONValue?
}

/// A single serve event: a request plus how WireMock handled it.
public struct ServeEvent: Codable, Sendable, Hashable {
    public var id: UUID?
    public var request: LoggedRequest
    public var responseDefinition: ResponseDefinition?
    /// The response actually sent (status/body/headers after rendering).
    public var response: LoggedResponse?
    public var wasMatched: Bool?
    public var stubMapping: StubMapping?
    /// Latency breakdown for this request.
    public var timing: Timing?
    /// Diagnostic sub-events the server attaches (e.g. the `REQUEST_NOT_MATCHED`
    /// diff report on an unmatched request).
    public var subEvents: [SubEvent]?
}

/// One expected-vs-actual difference contributing to a near miss.
public struct DiffDescription: Codable, Sendable, Hashable {
    public var expected: String?
    public var actual: String?
    public var errorMessage: String?
}

/// How close an unmatched request came to a stub.
public struct MatchResult: Codable, Sendable, Hashable {
    public var distance: Double?
    /// Human-readable expected-vs-actual diffs — the most useful near-miss
    /// diagnostic.
    public var diffDescriptions: [DiffDescription]?
    /// Diagnostic sub-events the server attaches to the match result.
    public var subEvents: [SubEvent]?
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
    let requestJournalDisabled: Bool?
}

struct FindRequestsResult: Decodable {
    let requests: [LoggedRequest]
    let requestJournalDisabled: Bool?
}

/// Envelope returned by `POST /__admin/requests/remove` (removed events).
struct RemovedServeEventsResult: Decodable {
    let serveEvents: [ServeEvent]
}

struct FindNearMissesResult: Decodable {
    let nearMisses: [NearMiss]
}
