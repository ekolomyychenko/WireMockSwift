import Foundation

/// An HTTP method. A `RawRepresentable` struct rather than a closed enum so
/// custom/extension verbs remain expressible, while the common verbs get
/// autocomplete and typo-safety.
///
/// ```swift
/// get(urlEqualTo("/x"))            // uses .get
/// request(.report, urlEqualTo("/x"))
/// request("REPORT", urlEqualTo("/x"))  // still works via the string literal
/// ```
public struct HTTPMethod: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let get: Self = "GET"
    public static let post: Self = "POST"
    public static let put: Self = "PUT"
    public static let patch: Self = "PATCH"
    public static let delete: Self = "DELETE"
    public static let head: Self = "HEAD"
    public static let options: Self = "OPTIONS"
    public static let trace: Self = "TRACE"
    /// Matches requests of any method.
    public static let any: Self = "ANY"
}
