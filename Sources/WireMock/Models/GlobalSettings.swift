import Foundation

/// Global server settings (`/__admin/settings`).
///
/// Decoding is lossless: recognised fields are typed, and any other keys the
/// server returns are preserved in `extended` (so nothing is silently dropped
/// on a round-trip).
public struct GlobalSettings: Codable, Sendable, Hashable {
    /// A fixed delay (ms) applied to every response.
    public var fixedDelay: Int?
    /// A random delay distribution applied to every response.
    public var delayDistribution: DelayDistribution?
    /// Whether unmatched requests are proxied through when a default proxy is set.
    public var proxyPassThrough: Bool?
    /// Any additional settings keys the server returned, preserved verbatim.
    public var extended: [String: JSONValue]

    public init(
        fixedDelay: Int? = nil,
        delayDistribution: DelayDistribution? = nil,
        proxyPassThrough: Bool? = nil,
        extended: [String: JSONValue] = [:]
    ) {
        self.fixedDelay = fixedDelay
        self.delayDistribution = delayDistribution
        self.proxyPassThrough = proxyPassThrough
        self.extended = extended
    }

    private static let knownKeys: Set<String> = ["fixedDelay", "delayDistribution", "proxyPassThrough"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.fixedDelay = try container.decodeIfPresent(Int.self, forKey: DynamicCodingKey("fixedDelay"))
        self.delayDistribution = try container.decodeIfPresent(DelayDistribution.self, forKey: DynamicCodingKey("delayDistribution"))
        self.proxyPassThrough = try container.decodeIfPresent(Bool.self, forKey: DynamicCodingKey("proxyPassThrough"))
        var extended: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extended[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extended = extended
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(fixedDelay, forKey: DynamicCodingKey("fixedDelay"))
        try container.encodeIfPresent(delayDistribution, forKey: DynamicCodingKey("delayDistribution"))
        try container.encodeIfPresent(proxyPassThrough, forKey: DynamicCodingKey("proxyPassThrough"))
        // Never let a stray known-key in `extended` produce a duplicate JSON key.
        for (key, value) in extended where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}
