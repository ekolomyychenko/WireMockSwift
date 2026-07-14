import Foundation

/// Criteria for extracting bodies to separate `__files` during recording.
public struct ExtractBodyCriteria: Codable, Sendable, Hashable {
    public var textSizeThreshold: String?
    public var binarySizeThreshold: String?

    public init(textSizeThreshold: String? = nil, binarySizeThreshold: String? = nil) {
        self.textSizeThreshold = textSizeThreshold
        self.binarySizeThreshold = binarySizeThreshold
    }
}

/// Filters limiting which requests are recorded/snapshotted. Java unwraps a full
/// `RequestPattern` here (plus `ids` and `allowNonProxied`), so all the URL/query
/// forms are available, not just `urlPathPattern`.
public struct RecordFilters: Codable, Sendable, Hashable {
    public var url: String?
    public var urlPattern: String?
    public var urlPath: String?
    public var urlPathPattern: String?
    public var urlPathTemplate: String?
    public var method: HTTPMethod?
    public var headers: [String: StringValuePattern]?
    public var queryParameters: [String: StringValuePattern]?
    /// Select specific serve events by id (snapshot only).
    public var ids: [String]?
    public var allowNonProxied: Bool?

    public init(
        url: String? = nil,
        urlPattern: String? = nil,
        urlPath: String? = nil,
        urlPathPattern: String? = nil,
        urlPathTemplate: String? = nil,
        method: HTTPMethod? = nil,
        headers: [String: StringValuePattern]? = nil,
        queryParameters: [String: StringValuePattern]? = nil,
        ids: [String]? = nil,
        allowNonProxied: Bool? = nil
    ) {
        self.url = url
        self.urlPattern = urlPattern
        self.urlPath = urlPath
        self.urlPathPattern = urlPathPattern
        self.urlPathTemplate = urlPathTemplate
        self.method = method
        self.headers = headers
        self.queryParameters = queryParameters
        self.ids = ids
        self.allowNonProxied = allowNonProxied
    }
}

/// Specification passed to `/__admin/recordings/start` and `/snapshot`.
public struct RecordSpec: Codable, Sendable, Hashable {
    public var targetBaseUrl: String?
    public var filters: RecordFilters?
    public var captureHeaders: [String: JSONValue]?
    public var extractBodyCriteria: ExtractBodyCriteria?
    public var requestBodyPattern: JSONValue?
    public var persist: Bool?
    public var repeatsAsScenarios: Bool?
    public var transformers: [String]?
    public var transformerParameters: [String: JSONValue]?
    public var outputFormat: String?

    public init(
        targetBaseUrl: String? = nil,
        filters: RecordFilters? = nil,
        captureHeaders: [String: JSONValue]? = nil,
        extractBodyCriteria: ExtractBodyCriteria? = nil,
        requestBodyPattern: JSONValue? = nil,
        persist: Bool? = nil,
        repeatsAsScenarios: Bool? = nil,
        transformers: [String]? = nil,
        transformerParameters: [String: JSONValue]? = nil,
        outputFormat: String? = nil
    ) {
        self.targetBaseUrl = targetBaseUrl
        self.filters = filters
        self.captureHeaders = captureHeaders
        self.extractBodyCriteria = extractBodyCriteria
        self.requestBodyPattern = requestBodyPattern
        self.persist = persist
        self.repeatsAsScenarios = repeatsAsScenarios
        self.transformers = transformers
        self.transformerParameters = transformerParameters
        self.outputFormat = outputFormat
    }
}

/// Result of stopping a recording or taking a snapshot. The server returns
/// exactly one shape: `{"mappings":[...]}` normally, or `{"ids":[...]}` when the
/// spec requests `outputFormat = "ids"`.
public struct SnapshotResult: Codable, Sendable, Hashable {
    public var mappings: [StubMapping]?
    /// Populated instead of `mappings` when the snapshot was taken with
    /// `outputFormat = "ids"`.
    public var ids: [String]?
}

/// Current recorder state.
public struct RecordingStatusResult: Codable, Sendable, Hashable {
    public var status: String?
}
