import XCTest
@testable import WireMock

/// Precision and equality tests for `JSONValue`, the type-erased JSON used for
/// `jsonBody`, the `equalToJson` operand, `metadata`, and transformer parameters.
///
/// The point of these tests is that numbers which do not fit `Double` — integers
/// larger than `Int64.max` and high-precision decimals — survive a decode→encode
/// round-trip byte-for-byte, matching Java/Jackson `BigInteger`/`BigDecimal`.
/// If they didn't, a `jsonBody` would ship wrong bytes and an `equalToJson`
/// operand would silently mis-match.
final class JSONValueTests: XCTestCase {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func roundTrip(_ json: String) throws -> String {
        try encode(decode(json))
    }

    // MARK: - Precision-preserving round-trips

    func testIntegerBeyondInt64RoundTripsByteExact() throws {
        // 20 digits, larger than Int64.max (9223372036854775807).
        let big = "12345678901234567890"
        XCTAssertEqual(try roundTrip(big), big, "a >Int64 integer must not degrade through Double")
        // Sanity: it lands in the precision-preserving case, not .double.
        guard case .decimal = try decode(big) else {
            return XCTFail("expected .decimal for a >Int64 integer")
        }
    }

    func testHighPrecisionDecimalRoundTripsByteExact() throws {
        let value = "10.123456789012345678"  // more precision than a Double holds
        XCTAssertEqual(try roundTrip(value), value)
        guard case .decimal = try decode(value) else {
            return XCTFail("expected .decimal for a high-precision decimal")
        }
    }

    func testInt64MaxRoundTripsExact() throws {
        // Fits Int exactly — stays .int, still byte-exact.
        let value = "9223372036854775807"
        XCTAssertEqual(try roundTrip(value), value)
        guard case .int = try decode(value) else {
            return XCTFail("expected .int for Int64.max")
        }
    }

    func testBigNumberSurvivesInsideJsonBody() throws {
        // The realistic path: a jsonBody carrying a large id.
        let body = JSONValue(parsing: #"{"id":12345678901234567890,"price":10.123456789012345678}"#)
        let encoded = try encode(try XCTUnwrap(body))
        XCTAssertTrue(encoded.contains("12345678901234567890"),
                      "big id must survive in jsonBody, got: \(encoded)")
        XCTAssertTrue(encoded.contains("10.123456789012345678"),
                      "high-precision decimal must survive in jsonBody, got: \(encoded)")
    }

    func testEqualToJsonOperandPreservesBigNumber() throws {
        // The operand of equalToJson must match the wire bytes exactly, or a
        // request Java would match silently fails to match here.
        let pattern = equalToJson(try XCTUnwrap(JSONValue(parsing: #"{"id":12345678901234567890}"#)))
        let encoded = String(decoding: try JSONEncoder().encode(pattern), as: UTF8.self)
        XCTAssertTrue(encoded.contains("12345678901234567890"), "operand lost precision: \(encoded)")
    }

    // MARK: - Cross-representation equality & hashing

    func testNumericEqualityAcrossRepresentations() throws {
        // 1 and 1.0 are the same JSON value; so are the decoded and literal forms.
        XCTAssertEqual(JSONValue.int(1), JSONValue.double(1.0))
        XCTAssertEqual(JSONValue.int(90), try decode("90"))
        XCTAssertEqual(JSONValue.double(1.5), try decode("1.5"))          // .double literal == .decimal decode
        XCTAssertEqual(try decode("1.5"), JSONValue.double(1.5))
        XCTAssertEqual(JSONValue.int(7), try decode("7.0"))              // .int == decoded 7.0
    }

    func testEqualValuesHashEqualAcrossRepresentations() throws {
        // Required for use as dictionary keys / in Sets: equal values must hash equal.
        let set: Set<JSONValue> = [.int(1), .double(1.0), try decode("1"), try decode("1.0")]
        XCTAssertEqual(set.count, 1, "1, 1.0, and their decoded forms must collapse to one element")

        XCTAssertEqual(JSONValue.double(1.5).hashValue, (try decode("1.5")).hashValue)
    }

    func testDistinctBigNumbersAreNotEqual() throws {
        // Precision must actually be compared — these differ only in the last digit.
        XCTAssertNotEqual(try decode("12345678901234567890"), try decode("12345678901234567891"))
    }

    // MARK: - Accessors

    func testNumericAccessors() throws {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.double(42.0).intValue, 42)
        XCTAssertNil(JSONValue.double(42.5).intValue)
        XCTAssertEqual((try decode("42")).intValue, 42)

        XCTAssertEqual(JSONValue.int(3).doubleValue, 3.0)
        XCTAssertEqual((try decode("1.5")).doubleValue, 1.5)

        XCTAssertEqual(JSONValue.int(5).decimalValue, Decimal(5))
        XCTAssertEqual((try decode("10.123456789012345678")).decimalValue,
                       Decimal(string: "10.123456789012345678"))
        XCTAssertNil(JSONValue.string("x").intValue)
        XCTAssertNil(JSONValue.string("x").decimalValue)
        XCTAssertNil(JSONValue.string("x").doubleValue)

        // .decimal intValue: whole large-but-Int-range decimals convert; fractional don't.
        XCTAssertEqual((try decode("123")).intValue, 123)          // decodes as .int
        XCTAssertEqual((try decode("123.0")).intValue, 123)         // .decimal whole → Int
        XCTAssertNil((try decode("123.5")).intValue)                // .decimal fractional → nil
        XCTAssertEqual((try decode("12345678901234567890")).intValue, nil,
                       ">Int range decimal has no exact Int")
        XCTAssertEqual((try decode("12345678901234567890")).doubleValue, 1.2345678901234568e19)

        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
    }

    func testNumberOutsideDecimalRangeFallsBackToDouble() throws {
        // 1e128 exceeds Decimal's exponent range (max 1e127) but is a finite
        // Double, so it decodes (lossily) as .double rather than throwing —
        // exercises the documented Double fallback.
        guard case .double = try decode("1e128") else {
            return XCTFail("expected .double fallback for an out-of-Decimal-range number")
        }
    }

    // MARK: - Structural round-trips still hold

    func testOrdinaryValuesUnaffected() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": nil]
        let round = try decode(encode(value))
        XCTAssertEqual(round, value)
    }
}
