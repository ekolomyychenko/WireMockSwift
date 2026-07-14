import XCTest
@testable import WireMock

/// Tests for `JSONValue`, the type-erased JSON used for `jsonBody`, the
/// `equalToJson` operand, `metadata`, and transformer parameters.
///
/// NOTE: `JSONValue` intentionally routes numbers through `Int`/`Double`.
/// Integers beyond `Int64` and decimals with more than ~15–17 significant
/// digits lose precision — a documented limitation (rare in mock bodies). A
/// `Decimal`-backed variant was tried and reverted: `JSONDecoder.decode(Decimal.self)`
/// traps rather than throwing on the older Darwin Foundation, crashing the
/// background decode path. See the README limitations note.
final class JSONValueTests: XCTestCase {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    func testNumericEqualityIsByMagnitude() throws {
        // JSON has one number type: 1 and 1.0 are the same value.
        XCTAssertEqual(JSONValue.int(1), JSONValue.double(1.0))
        XCTAssertEqual(JSONValue.int(90), try decode("90"))
        XCTAssertEqual(JSONValue.double(1.5), try decode("1.5"))
    }

    func testEqualNumbersHashEqual() throws {
        let set: Set<JSONValue> = [.int(1), .double(1.0), try decode("1")]
        XCTAssertEqual(set.count, 1, "1 and 1.0 must collapse to one element")
    }

    func testIntegerAndDoubleDecodeToExpectedCases() throws {
        guard case .int = try decode("42") else { return XCTFail("42 should decode as .int") }
        guard case .double = try decode("42.5") else { return XCTFail("42.5 should decode as .double") }
    }

    func testStringAndParsingAccessors() throws {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertEqual(JSONValue(parsing: #"{"a":1}"#)?.objectValue?["a"], .int(1))
        XCTAssertNil(JSONValue(parsing: "{not json"))
    }

    func testOrdinaryValuesRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": nil]
        XCTAssertEqual(try decode(encode(value)), value)
    }

    func testBigNumberPrecisionIsDocumentedLossy() throws {
        // Documents the known limitation: a >Int64 integer degrades through Double.
        // (Kept as an explicit contract so a future precision fix has a target.)
        let decoded = try decode("12345678901234567890")
        guard case .double = decoded else {
            return XCTFail("a >Int64 integer currently decodes as .double")
        }
    }
}
