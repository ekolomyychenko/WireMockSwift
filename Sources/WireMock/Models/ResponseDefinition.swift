import Foundation

/// A response header value: either a single value or multiple values
/// (e.g. multiple `Set-Cookie` headers). Encodes as a bare string or a JSON
/// array of strings, matching WireMock.
public enum HeaderValue: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, CustomStringConvertible {
    case single(String)
    case multiple([String])

    public var description: String {
        switch self {
        case .single(let value): return value
        case .multiple(let values): return "[" + values.joined(separator: ", ") + "]"
        }
    }

    public init(stringLiteral value: String) { self = .single(value) }
    public init(arrayLiteral elements: String...) { self = .multiple(elements) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value): try container.encode(value)
        case .multiple(let values): try container.encode(values)
        }
    }
}

/// Random delay distribution applied to a response.
public enum DelayDistribution: Codable, Sendable, Hashable {
    /// `maxValue` optionally caps the sampled delay (milliseconds).
    case lognormal(median: Double, sigma: Double, maxValue: Double? = nil)
    case uniform(lower: Int, upper: Int)
    /// Any distribution type this library doesn't model yet, preserved verbatim
    /// so decoding a newer server's settings never fails.
    case other(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, median, sigma, lower, upper, maxValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing/odd `type` falls through to `.other` rather than throwing, so
        // the fallback actually holds its promise of never failing the decode.
        let type = try? container.decode(String.self, forKey: .type)
        switch type {
        case "lognormal":
            self = .lognormal(
                median: try container.decode(Double.self, forKey: .median),
                sigma: try container.decode(Double.self, forKey: .sigma),
                maxValue: try container.decodeIfPresent(Double.self, forKey: .maxValue)
            )
        case "uniform":
            self = .uniform(
                lower: try container.decode(Int.self, forKey: .lower),
                upper: try container.decode(Int.self, forKey: .upper)
            )
        default:
            // Don't fail the whole enclosing decode on an unrecognised type.
            self = .other(try decoder.singleValueContainer().decode(JSONValue.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .lognormal(let median, let sigma, let maxValue):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("lognormal", forKey: .type)
            try container.encode(median, forKey: .median)
            try container.encode(sigma, forKey: .sigma)
            try container.encodeIfPresent(maxValue, forKey: .maxValue)
        case .uniform(let lower, let upper):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("uniform", forKey: .type)
            try container.encode(lower, forKey: .lower)
            try container.encode(upper, forKey: .upper)
        case .other(let raw):
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        }
    }
}

/// Chunked "dribble" delay — the body is split into `numberOfChunks` pieces
/// spread evenly over `totalDuration` milliseconds.
public struct ChunkedDribbleDelay: Codable, Sendable, Hashable {
    public var numberOfChunks: Int
    public var totalDuration: Int

    public init(numberOfChunks: Int, totalDuration: Int) {
        self.numberOfChunks = numberOfChunks
        self.totalDuration = totalDuration
    }
}

/// Low-level connection faults WireMock can simulate.
public enum Fault: Codable, Sendable, Hashable, CustomStringConvertible {
    case emptyResponse
    case malformedResponseChunk
    case randomDataThenClose
    case connectionResetByPeer
    /// Any fault value this library doesn't model yet, preserved verbatim so
    /// decoding a newer server's mapping (e.g. inside a bulk `listAllStubMappings`)
    /// never fails.
    case other(String)

    public var description: String { wireValue }   // "EMPTY_RESPONSE", …

    private var wireValue: String {
        switch self {
        case .emptyResponse: return "EMPTY_RESPONSE"
        case .malformedResponseChunk: return "MALFORMED_RESPONSE_CHUNK"
        case .randomDataThenClose: return "RANDOM_DATA_THEN_CLOSE"
        case .connectionResetByPeer: return "CONNECTION_RESET_BY_PEER"
        case .other(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "EMPTY_RESPONSE": self = .emptyResponse
        case "MALFORMED_RESPONSE_CHUNK": self = .malformedResponseChunk
        case "RANDOM_DATA_THEN_CLOSE": self = .randomDataThenClose
        case "CONNECTION_RESET_BY_PEER": self = .connectionResetByPeer
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The `response` half of a stub mapping. Mirrors WireMock's
/// `ResponseDefinition` JSON; unset fields are omitted.
public struct ResponseDefinition: Codable, Sendable, Hashable {
    public var status: Int?
    public var statusMessage: String?
    public var body: String?
    public var jsonBody: JSONValue?
    public var base64Body: String?
    public var bodyFileName: String?
    public var headers: [String: HeaderValue]?
    public var fixedDelayMilliseconds: Int?
    public var delayDistribution: DelayDistribution?
    public var chunkedDribbleDelay: ChunkedDribbleDelay?
    public var fault: Fault?
    public var transformers: [String]?
    public var transformerParameters: [String: JSONValue]?
    public var proxyBaseUrl: String?
    public var additionalProxyRequestHeaders: [String: HeaderValue]?
    public var removeProxyRequestHeaders: [String]?
    public var proxyUrlPrefixToRemove: String?

    public init() {}
}
