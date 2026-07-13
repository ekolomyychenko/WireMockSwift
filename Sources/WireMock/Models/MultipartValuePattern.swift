import Foundation

/// A matcher for one part of a `multipart/form-data` request body.
///
/// Mirrors WireMock's `multipartPatterns` entries.
public struct MultipartValuePattern: Codable, Sendable, Hashable {
    /// Whether the part must match ALL or ANY of the given patterns.
    public enum MatchingType: String, Codable, Sendable, Hashable {
        case all = "ALL"
        case any = "ANY"
    }

    public var name: String?
    public var matchingType: MatchingType?
    public var headers: [String: StringValuePattern]?
    public var bodyPatterns: [StringValuePattern]?

    public init(
        name: String? = nil,
        matchingType: MatchingType? = nil,
        headers: [String: StringValuePattern]? = nil,
        bodyPatterns: [StringValuePattern]? = nil
    ) {
        self.name = name
        self.matchingType = matchingType
        self.headers = headers
        self.bodyPatterns = bodyPatterns
    }
}
