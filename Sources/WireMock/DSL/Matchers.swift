import Foundation

// Free-function matcher builders that mirror WireMock's Java static DSL
// (`equalTo`, `containing`, `matchingJsonPath`, …). Each returns a
// `StringValuePattern` usable for headers, query params, cookies, or bodies.

public func equalTo(_ value: String, caseInsensitive: Bool = false) -> StringValuePattern {
    .equalTo(value, caseInsensitive: caseInsensitive)
}

public func equalToIgnoreCase(_ value: String) -> StringValuePattern {
    .equalTo(value, caseInsensitive: true)
}

public func binaryEqualTo(_ base64: String) -> StringValuePattern {
    .binaryEqualTo(base64)
}

/// Matches a request body byte-for-byte against the given bytes (Java's
/// `binaryEqualTo(byte[])`). The bytes are Base64-encoded on the wire.
public func binaryEqualTo(_ data: Data) -> StringValuePattern {
    .binaryEqualTo(data)
}

public func containing(_ value: String) -> StringValuePattern {
    .containing(value)
}

public func notContaining(_ value: String) -> StringValuePattern {
    .notContaining(value)
}

public func matching(_ regex: String) -> StringValuePattern {
    .matching(regex)
}

public func notMatching(_ regex: String) -> StringValuePattern {
    .notMatching(regex)
}

public var absent: StringValuePattern { .absent }

/// Matches any value (WireMock's `anything()`).
public var anything: StringValuePattern { .anything }

public func equalToJson(
    _ json: JSONValue,
    ignoreArrayOrder: Bool = false,
    ignoreExtraElements: Bool = false
) -> StringValuePattern {
    .equalToJson(json, ignoreArrayOrder: ignoreArrayOrder, ignoreExtraElements: ignoreExtraElements)
}

public func equalToJson(
    raw json: String,
    ignoreArrayOrder: Bool = false,
    ignoreExtraElements: Bool = false
) throws -> StringValuePattern {
    try .equalToJson(raw: json, ignoreArrayOrder: ignoreArrayOrder, ignoreExtraElements: ignoreExtraElements)
}

public func matchingJsonPath(_ expression: String) -> StringValuePattern {
    .matchingJsonPath(expression)
}

public func matchingJsonPath(_ expression: String, _ submatcher: StringValuePattern) -> StringValuePattern {
    .matchingJsonPath(expression, submatcher)
}

public func equalToXml(_ xml: String) -> StringValuePattern {
    .equalToXml(xml)
}

public func matchingXPath(_ expression: String, namespaces: [String: String] = [:]) -> StringValuePattern {
    .matchingXPath(expression, namespaces: namespaces)
}

/// XPath with a nested sub-matcher applied to the extracted value.
public func matchingXPath(_ expression: String, _ submatcher: StringValuePattern, namespaces: [String: String] = [:]) -> StringValuePattern {
    .matchingXPath(expression, submatcher, namespaces: namespaces)
}

public func and(_ patterns: StringValuePattern...) -> StringValuePattern { .and(patterns) }
public func or(_ patterns: StringValuePattern...) -> StringValuePattern { .or(patterns) }
public func not(_ pattern: StringValuePattern) -> StringValuePattern { .not(pattern) }

// MARK: Multi-value (repeated params)

public func hasExactly(_ patterns: StringValuePattern...) -> StringValuePattern { .hasExactly(patterns) }
public func includes(_ patterns: StringValuePattern...) -> StringValuePattern { .includes(patterns) }

// MARK: Numeric comparison — not available on WireMock 3.13.2.
//
// Numeric comparison matchers (equalToNumber/greaterThan/lessThan/…) are a
// WireMock 4.0+ feature; the 3.13.2 server rejects them with HTTP 422. They are
// therefore not part of this DSL. On 3.x, match numbers with a JSONPath
// predicate instead:
//   withRequestBody(matchingJsonPath("$[?(@.age > 5)]"))

// MARK: Date / time

public func before(
    _ dateTime: String,
    actualFormat: String? = nil,
    truncateExpected: String? = nil,
    truncateActual: String? = nil,
    expectedOffset: Int? = nil,
    expectedOffsetUnit: StringValuePattern.DateTimeUnit? = nil,
    applyTruncationLast: Bool? = nil
) -> StringValuePattern {
    .before(dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
            truncateActual: truncateActual, expectedOffset: expectedOffset,
            expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
}

public func after(
    _ dateTime: String,
    actualFormat: String? = nil,
    truncateExpected: String? = nil,
    truncateActual: String? = nil,
    expectedOffset: Int? = nil,
    expectedOffsetUnit: StringValuePattern.DateTimeUnit? = nil,
    applyTruncationLast: Bool? = nil
) -> StringValuePattern {
    .after(dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
           truncateActual: truncateActual, expectedOffset: expectedOffset,
           expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
}

public func equalToDateTime(
    _ dateTime: String,
    actualFormat: String? = nil,
    truncateExpected: String? = nil,
    truncateActual: String? = nil,
    expectedOffset: Int? = nil,
    expectedOffsetUnit: StringValuePattern.DateTimeUnit? = nil,
    applyTruncationLast: Bool? = nil
) -> StringValuePattern {
    .equalToDateTime(dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
                     truncateActual: truncateActual, expectedOffset: expectedOffset,
                     expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
}

/// Matches a date/time before the current moment (`beforeNow()` in Java).
public func beforeNow() -> StringValuePattern { .before("now") }
/// Matches a date/time after the current moment (`afterNow()` in Java).
public func afterNow() -> StringValuePattern { .after("now") }
/// Matches a date/time equal to the current moment (`isNow()` in Java).
public func isNow() -> StringValuePattern { .equalToDateTime("now") }

// MARK: JSON schema

public func matchingJsonSchema(
    _ schema: JSONValue,
    version: StringValuePattern.JSONSchemaVersion? = nil
) -> StringValuePattern {
    .matchingJsonSchema(schema, version: version)
}

/// JSON-schema matcher from a raw schema string (throws on malformed JSON,
/// symmetric with `equalToJson(raw:)`).
public func matchingJsonSchema(
    raw schema: String,
    version: StringValuePattern.JSONSchemaVersion? = nil
) throws -> StringValuePattern {
    try .matchingJsonSchema(raw: schema, version: version)
}
