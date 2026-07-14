import Foundation

// String representations for logging (e.g. Allure). Mirrors Java WireMock, whose
// `toString()` returns the object's JSON (`Json.write(this)`). Container types
// therefore describe as pretty JSON; leaf scalars (HTTPMethod, HeaderValue,
// Fault, JSONValue, …) describe as their bare value — see the per-type files.
//
// NOTE: only object/array-encoding types go through `JSONDescribed`. Encoding a
// *top-level scalar* (bare string/number/bool) via `JSONEncoder` throws
// "Top-level … encoded as … fragment" on the older Darwin Foundation, so scalar
// leaves must not use this path.

/// Shared encoder for `description`s — pretty, stable key order, readable slashes.
private let descriptionEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// The WireMock-JSON form of an `Encodable`, for use as a `description`.
/// Falls back to the type name if encoding somehow fails (never traps).
func wiremockJSONDescription<T: Encodable>(_ value: T) -> String {
    guard let data = try? descriptionEncoder.encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "\(type(of: value))"
    }
    return string
}

/// A type whose `description` is its WireMock JSON (mirrors Java `toString()`).
/// Adopt only on types that encode as a JSON object/array, never a bare scalar.
public protocol JSONDescribed: CustomStringConvertible, Encodable {}

public extension JSONDescribed {
    var description: String { wiremockJSONDescription(self) }
}

// MARK: - Container conformances (encode as JSON objects)

extension StubMapping: JSONDescribed {}
extension RequestPattern: JSONDescribed {}
extension BasicAuthCredentials: JSONDescribed {}
extension CustomMatcherDefinition: JSONDescribed {}
extension ResponseDefinition: JSONDescribed {}
extension ChunkedDribbleDelay: JSONDescribed {}
extension DelayDistribution: JSONDescribed {}
extension GlobalSettings: JSONDescribed {}
extension MultipartValuePattern: JSONDescribed {}
extension ServeEventListenerDefinition: JSONDescribed {}
extension RecordSpec: JSONDescribed {}
extension RecordFilters: JSONDescribed {}
extension ExtractBodyCriteria: JSONDescribed {}
extension SnapshotResult: JSONDescribed {}
extension RecordingStatusResult: JSONDescribed {}
extension Scenario: JSONDescribed {}
extension StringValuePattern: JSONDescribed {}

// Journal / verification result types (the heart of Allure request logging).
extension LoggedRequest: JSONDescribed {}
extension LoggedResponse: JSONDescribed {}
extension Timing: JSONDescribed {}
extension ServeEvent: JSONDescribed {}
extension DiffDescription: JSONDescribed {}
extension MatchResult: JSONDescribed {}
extension NearMiss: JSONDescribed {}

// MARK: - Raw-value enums → wire value

extension MultipartValuePattern.MatchingType: CustomStringConvertible {
    public var description: String { rawValue }   // "ALL" / "ANY"
}
extension StringValuePattern.JSONSchemaVersion: CustomStringConvertible {
    public var description: String { rawValue }
}
extension StringValuePattern.NamespaceAwareness: CustomStringConvertible {
    public var description: String { rawValue }   // "STRICT" / "NONE" / "LEGACY"
}
extension WireMock.DuplicatePolicy: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Builders → JSON of the model they build

extension MappingBuilder: CustomStringConvertible {
    public var description: String { wiremockJSONDescription(build()) }
}
extension RequestPatternBuilder: CustomStringConvertible {
    public var description: String { wiremockJSONDescription(pattern) }
}
extension ResponseDefinitionBuilder: CustomStringConvertible {
    public var description: String { wiremockJSONDescription(definition) }
}
extension ProxyResponseDefinitionBuilder: CustomStringConvertible {
    public var description: String { wiremockJSONDescription(definition) }
}

// MARK: - WebhookDefinition (not Codable) → JSON of its listener form

extension WebhookDefinition: CustomStringConvertible {
    public var description: String { wiremockJSONDescription(asServeEventListener()) }
}
