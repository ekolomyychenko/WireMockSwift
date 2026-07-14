import Foundation

/// Global server settings (`/__admin/settings`).
public struct GlobalSettings: Codable, Sendable, Hashable {
    /// A fixed delay (ms) applied to every response.
    public var fixedDelay: Int?
    /// A random delay distribution applied to every response.
    public var delayDistribution: DelayDistribution?
    /// Whether unmatched requests are proxied through when a default proxy is set.
    public var proxyPassThrough: Bool?
    /// Extension-specific settings, carried under the server's nested `extended`
    /// object. Java's `GlobalSettings.extended` is a nested map, NOT top-level
    /// keys — a top-level unknown setting key is silently ignored by the server,
    /// so extension settings must live here (e.g. `["custom": .int(1)]` →
    /// `{"extended": {"custom": 1}}`).
    public var extended: [String: JSONValue]?

    public init(
        fixedDelay: Int? = nil,
        delayDistribution: DelayDistribution? = nil,
        proxyPassThrough: Bool? = nil,
        extended: [String: JSONValue]? = nil
    ) {
        self.fixedDelay = fixedDelay
        self.delayDistribution = delayDistribution
        self.proxyPassThrough = proxyPassThrough
        self.extended = extended
    }
    // Synthesized Codable encodes `extended` as the nested `"extended"` object
    // and omits any nil field; unknown server keys are ignored on decode.
}
