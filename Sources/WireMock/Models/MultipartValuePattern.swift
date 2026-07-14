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
    /// Matches the part's filename by exact string equality (WireMock compares
    /// it verbatim against the part's `Content-Disposition` filename — it is not
    /// a `StringValuePattern`).
    public var fileName: String?
    public var matchingType: MatchingType?
    public var headers: [String: StringValuePattern]?
    public var bodyPatterns: [StringValuePattern]?

    public init(
        name: String? = nil,
        fileName: String? = nil,
        matchingType: MatchingType? = nil,
        headers: [String: StringValuePattern]? = nil,
        bodyPatterns: [StringValuePattern]? = nil
    ) {
        self.name = name
        self.fileName = fileName
        self.matchingType = matchingType
        self.headers = headers
        self.bodyPatterns = bodyPatterns
    }
}
