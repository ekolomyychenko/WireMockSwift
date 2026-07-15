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

/// Fluent builder for a `MultipartValuePattern` (Java `MultipartValuePatternBuilder`,
/// entry point `aMultipart()`). Value-typed, like the other builders: each
/// `with…` returns a modified copy.
public struct MultipartValuePatternBuilder: Sendable {
    private var pattern: MultipartValuePattern

    public init(name: String? = nil) {
        self.pattern = MultipartValuePattern(name: name)
    }

    private func mutating(_ transform: (inout MultipartValuePattern) -> Void) -> Self {
        var copy = self
        transform(&copy.pattern)
        return copy
    }

    public func withName(_ name: String) -> Self { mutating { $0.name = name } }
    public func withFileName(_ fileName: String) -> Self { mutating { $0.fileName = fileName } }

    /// Whether the part must match ALL or ANY of the given body patterns.
    public func matchingType(_ type: MultipartValuePattern.MatchingType) -> Self {
        mutating { $0.matchingType = type }
    }

    public func withHeader(_ name: String, _ valuePattern: StringValuePattern) -> Self {
        mutating { var headers = $0.headers ?? [:]; headers[name] = valuePattern; $0.headers = headers }
    }

    /// Adds a body matcher for the part (`withBody` in Java).
    public func withBody(_ bodyPattern: StringValuePattern) -> Self {
        mutating { $0.bodyPatterns = ($0.bodyPatterns ?? []) + [bodyPattern] }
    }

    public func build() -> MultipartValuePattern { pattern }
}

/// Entry point for the multipart matcher builder (`aMultipart()` in Java).
public func aMultipart() -> MultipartValuePatternBuilder { MultipartValuePatternBuilder() }

/// Entry point naming the part (`aMultipart(name)` in Java).
public func aMultipart(_ name: String) -> MultipartValuePatternBuilder { MultipartValuePatternBuilder(name: name) }
