import Foundation

/// A dynamic coding key so we can encode/decode matcher objects whose keys
/// vary at runtime (`equalTo`, `matches`, `equalToJson`, …).
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A WireMock "string value pattern" — the object form used for matching
/// headers, query params, cookies, and request bodies, e.g.
/// `{ "equalTo": "text/plain", "caseInsensitive": true }`.
///
/// Encodes its `fields` inline as a flat JSON object, mirroring the server
/// contract exactly. Build instances with the static factories (or the free
/// functions in `Matchers.swift`).
public struct StringValuePattern: Codable, Sendable, Hashable {
    /// The raw matcher fields. Read-only from outside; construct via the typed
    /// factories (or `init(_:)` as a deliberate escape hatch).
    public private(set) var fields: [String: JSONValue]

    /// Escape hatch: build a matcher from raw fields for any operator not yet
    /// modelled by a typed factory.
    public init(_ fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var result: [String: JSONValue] = [:]
        for key in container.allKeys {
            result[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.fields = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in fields {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    /// The pattern as a nested JSON object — used when embedding inside
    /// logical `and`/`or`/`not` combinators.
    var asJSON: JSONValue { .object(fields) }
}

extension StringValuePattern: ExpressibleByStringLiteral {
    /// A bare string literal is shorthand for `.equalTo(...)`, so request-side
    /// `withHeader("Accept", "application/json")` reads the same as the
    /// response side.
    public init(stringLiteral value: String) {
        self = .equalTo(value)
    }
}

// MARK: - Factories (mirror WireMock's Java matchers)

extension StringValuePattern {
    public static func equalTo(_ value: String, caseInsensitive: Bool = false) -> Self {
        var fields: [String: JSONValue] = ["equalTo": .string(value)]
        if caseInsensitive { fields["caseInsensitive"] = true }
        return .init(fields)
    }

    public static func binaryEqualTo(_ base64: String) -> Self {
        .init(["binaryEqualTo": .string(base64)])
    }

    /// Matches a request body byte-for-byte against the given bytes (Java's
    /// `binaryEqualTo(byte[])`). The bytes are Base64-encoded on the wire.
    public static func binaryEqualTo(_ data: Data) -> Self {
        .init(["binaryEqualTo": .string(data.base64EncodedString())])
    }

    public static func containing(_ value: String) -> Self {
        .init(["contains": .string(value)])
    }

    public static func notContaining(_ value: String) -> Self {
        .init(["doesNotContain": .string(value)])
    }

    public static func matching(_ regex: String) -> Self {
        .init(["matches": .string(regex)])
    }

    public static func notMatching(_ regex: String) -> Self {
        .init(["doesNotMatch": .string(regex)])
    }

    public static var absent: Self {
        .init(["absent": true])
    }

    /// Matches any value (WireMock's `anything()` / `AnythingPattern`).
    public static var anything: Self {
        // `AnythingPattern.getAnything()` serialises the literal "anything"
        // (the internal "(always)" default operand is never written to the
        // wire), so this matches what a Java-authored mapping round-trips to.
        .init(["anything": "anything"])
    }

    public static func equalToJson(
        _ json: JSONValue,
        ignoreArrayOrder: Bool = false,
        ignoreExtraElements: Bool = false
    ) -> Self {
        var fields: [String: JSONValue] = ["equalToJson": json]
        if ignoreArrayOrder { fields["ignoreArrayOrder"] = true }
        if ignoreExtraElements { fields["ignoreExtraElements"] = true }
        return .init(fields)
    }

    public static func equalToJson(
        raw json: String,
        ignoreArrayOrder: Bool = false,
        ignoreExtraElements: Bool = false
    ) throws -> Self {
        // Surface malformed JSON loudly (like `register(raw:)`) instead of
        // silently degrading to a `.string` matcher that compares the body
        // against the literal text and never fires.
        guard let value = JSONValue(parsing: json) else {
            throw WireMockError.decodingFailed(underlying: "equalToJson(raw:) was given invalid JSON")
        }
        return equalToJson(value, ignoreArrayOrder: ignoreArrayOrder, ignoreExtraElements: ignoreExtraElements)
    }

    public static func matchingJsonPath(_ expression: String) -> Self {
        .init(["matchesJsonPath": .string(expression)])
    }

    /// JSONPath with a nested sub-matcher, e.g.
    /// `{ "matchesJsonPath": { "expression": "$.name", "contains": "bob" } }`.
    public static func matchingJsonPath(_ expression: String, _ submatcher: StringValuePattern) -> Self {
        var object = submatcher.fields
        object["expression"] = .string(expression)
        return .init(["matchesJsonPath": .object(object)])
    }

    public static func equalToXml(_ xml: String) -> Self {
        .init(["equalToXml": .string(xml)])
    }

    public static func matchingXPath(_ expression: String, namespaces: [String: String] = [:]) -> Self {
        var fields: [String: JSONValue] = ["matchesXPath": .string(expression)]
        if !namespaces.isEmpty {
            fields["xPathNamespaces"] = .object(namespaces.mapValues { .string($0) })
        }
        return .init(fields)
    }

    // MARK: Logical combinators

    public static func and(_ patterns: [StringValuePattern]) -> Self {
        .init(["and": .array(patterns.map(\.asJSON))])
    }

    public static func or(_ patterns: [StringValuePattern]) -> Self {
        .init(["or": .array(patterns.map(\.asJSON))])
    }

    public static func not(_ pattern: StringValuePattern) -> Self {
        .init(["not": pattern.asJSON])
    }
}
