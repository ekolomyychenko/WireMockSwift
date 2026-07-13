import Foundation

// Additional matchers beyond the common string operators: numeric, date/time,
// JSON-schema, and XML with options. Keys mirror the WireMock 3.x contract.

extension StringValuePattern {

    // MARK: Numeric comparison
    //
    // NOTE: numeric comparison matchers require **WireMock 4.0+**. On WireMock
    // 3.x the server rejects these keys ("not a valid match operation", HTTP
    // 422). The JSON shape here matches the 4.x contract.

    public static func equalToNumber(_ value: Double) -> Self { .init(["equalToNumber": .double(value)]) }
    public static func greaterThan(_ value: Double) -> Self { .init(["greaterThanNumber": .double(value)]) }
    public static func greaterThanOrEqual(_ value: Double) -> Self { .init(["greaterThanEqualNumber": .double(value)]) }
    public static func lessThan(_ value: Double) -> Self { .init(["lessThanNumber": .double(value)]) }
    public static func lessThanOrEqual(_ value: Double) -> Self { .init(["lessThanEqualNumber": .double(value)]) }

    // MARK: Date / time

    private static func dateTime(
        _ key: String,
        _ value: String,
        actualFormat: String?,
        truncateExpected: String?,
        truncateActual: String?,
        expectedOffset: Int?,
        expectedOffsetUnit: String?,
        applyTruncationLast: Bool?
    ) -> Self {
        var fields: [String: JSONValue] = [key: .string(value)]
        if let actualFormat { fields["actualFormat"] = .string(actualFormat) }
        if let truncateExpected { fields["truncateExpected"] = .string(truncateExpected) }
        if let truncateActual { fields["truncateActual"] = .string(truncateActual) }
        if let expectedOffset { fields["expectedOffset"] = .int(expectedOffset) }
        if let expectedOffsetUnit { fields["expectedOffsetUnit"] = .string(expectedOffsetUnit) }
        if let applyTruncationLast { fields["applyTruncationLast"] = .bool(applyTruncationLast) }
        return .init(fields)
    }

    public static func before(
        _ dateTime: String,
        actualFormat: String? = nil,
        truncateExpected: String? = nil,
        truncateActual: String? = nil,
        expectedOffset: Int? = nil,
        expectedOffsetUnit: String? = nil,
        applyTruncationLast: Bool? = nil
    ) -> Self {
        self.dateTime("before", dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
                      truncateActual: truncateActual, expectedOffset: expectedOffset,
                      expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
    }

    public static func after(
        _ dateTime: String,
        actualFormat: String? = nil,
        truncateExpected: String? = nil,
        truncateActual: String? = nil,
        expectedOffset: Int? = nil,
        expectedOffsetUnit: String? = nil,
        applyTruncationLast: Bool? = nil
    ) -> Self {
        self.dateTime("after", dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
                      truncateActual: truncateActual, expectedOffset: expectedOffset,
                      expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
    }

    public static func equalToDateTime(
        _ dateTime: String,
        actualFormat: String? = nil,
        truncateExpected: String? = nil,
        truncateActual: String? = nil,
        expectedOffset: Int? = nil,
        expectedOffsetUnit: String? = nil,
        applyTruncationLast: Bool? = nil
    ) -> Self {
        self.dateTime("equalToDateTime", dateTime, actualFormat: actualFormat, truncateExpected: truncateExpected,
                      truncateActual: truncateActual, expectedOffset: expectedOffset,
                      expectedOffsetUnit: expectedOffsetUnit, applyTruncationLast: applyTruncationLast)
    }

    // MARK: JSON schema

    /// JSON Schema versions supported by WireMock.
    public enum JSONSchemaVersion: String, Sendable {
        case v4 = "V4", v6 = "V6", v7 = "V7", v201909 = "V201909", v202012 = "V202012"
    }

    public static func matchingJsonSchema(_ schema: JSONValue, version: JSONSchemaVersion? = nil) -> Self {
        var fields: [String: JSONValue] = ["matchesJsonSchema": schema]
        if let version { fields["schemaVersion"] = .string(version.rawValue) }
        return .init(fields)
    }

    public static func matchingJsonSchema(raw schema: String, version: JSONSchemaVersion? = nil) -> Self {
        matchingJsonSchema(JSONValue(parsing: schema) ?? .string(schema), version: version)
    }

    // MARK: XML with options

    public static func equalToXml(
        _ xml: String,
        enablePlaceholders: Bool = false,
        placeholderOpeningDelimiterRegex: String? = nil,
        placeholderClosingDelimiterRegex: String? = nil,
        exemptedComparisons: [String]? = nil,
        ignoreOrderOfSameNode: Bool? = nil
    ) -> Self {
        var fields: [String: JSONValue] = ["equalToXml": .string(xml)]
        if enablePlaceholders { fields["enablePlaceholders"] = true }
        if let placeholderOpeningDelimiterRegex { fields["placeholderOpeningDelimiterRegex"] = .string(placeholderOpeningDelimiterRegex) }
        if let placeholderClosingDelimiterRegex { fields["placeholderClosingDelimiterRegex"] = .string(placeholderClosingDelimiterRegex) }
        if let exemptedComparisons { fields["exemptedComparisons"] = .array(exemptedComparisons.map { .string($0) }) }
        if let ignoreOrderOfSameNode { fields["ignoreOrderOfSameNode"] = .bool(ignoreOrderOfSameNode) }
        return .init(fields)
    }

    // MARK: Multi-value (repeated query/header/form params)

    /// Matches a multi-value param that has EXACTLY the given values (order and
    /// count must match), each described by a sub-matcher.
    public static func hasExactly(_ patterns: [StringValuePattern]) -> Self {
        .init(["hasExactly": .array(patterns.map(\.asJSON))])
    }

    /// Matches a multi-value param that INCLUDES values satisfying the given
    /// sub-matchers (others may also be present).
    public static func includes(_ patterns: [StringValuePattern]) -> Self {
        .init(["includes": .array(patterns.map(\.asJSON))])
    }

    /// XPath with a nested sub-matcher applied to the extracted value.
    public static func matchingXPath(_ expression: String, _ submatcher: StringValuePattern, namespaces: [String: String] = [:]) -> Self {
        var object = submatcher.fields
        object["expression"] = .string(expression)
        var fields: [String: JSONValue] = ["matchesXPath": .object(object)]
        if !namespaces.isEmpty {
            fields["xPathNamespaces"] = .object(namespaces.mapValues { .string($0) })
        }
        return .init(fields)
    }
}
