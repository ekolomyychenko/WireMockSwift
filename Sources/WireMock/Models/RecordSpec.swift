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

/// Filters limiting which requests are recorded.
public struct RecordFilters: Codable, Sendable, Hashable {
    public var urlPathPattern: String?
    public var method: HTTPMethod?
    public var headers: [String: StringValuePattern]?
    public var allowNonProxied: Bool?

    public init(
        urlPathPattern: String? = nil,
        method: HTTPMethod? = nil,
        headers: [String: StringValuePattern]? = nil,
        allowNonProxied: Bool? = nil
    ) {
        self.urlPathPattern = urlPathPattern
        self.method = method
        self.headers = headers
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

/// Result of stopping a recording or taking a snapshot.
public struct SnapshotResult: Codable, Sendable, Hashable {
    public var mappings: [StubMapping]?
}

/// Current recorder state.
public struct RecordingStatusResult: Codable, Sendable, Hashable {
    public var status: String?
}
