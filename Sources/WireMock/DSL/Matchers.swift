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

// MARK: Numeric — WireMock 4.0+ only.
//
// Numeric comparison matchers are intentionally NOT exposed as unqualified free
// functions — PRIMARILY because they are dead-on-arrival on WireMock 3.x (the
// server rejects the keys with HTTP 422), so a global `greaterThan`/`lessThan`
// would be a footgun that always fails at stub-registration time. (The other
// global matchers — `and`/`or`/`not`/`before`/`after` — DO work on 3.x, so they
// remain free functions mirroring the Java DSL.) Use the explicit factories
// when targeting WireMock 4.0+: `StringValuePattern.greaterThan(5)`, etc.
//
// On WireMock 3.x, match numbers with a JSONPath predicate instead:
//   withRequestBody(matchingJsonPath("$[?(@.age > 5)]"))

// MARK: Date / time

public func before(_ dateTime: String) -> StringValuePattern { .before(dateTime) }
public func after(_ dateTime: String) -> StringValuePattern { .after(dateTime) }
public func equalToDateTime(_ dateTime: String) -> StringValuePattern { .equalToDateTime(dateTime) }

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
