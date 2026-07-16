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

    func testNumericEqualityIsByMagnitude() throws {
        // JSON has one number type: 1 and 1.0 are the same value.
        XCTAssertEqual(JSONValue.int(1), JSONValue.double(1.0))
        XCTAssertEqual(JSONValue.int(90), try WireMockFixture.decode(JSONValue.self, "90"))
        XCTAssertEqual(JSONValue.double(1.5), try WireMockFixture.decode(JSONValue.self, "1.5"))
        // Negatives: magnitude must actually be compared, and cross-kind stays
        // unequal — kills a `==` that returns true unconditionally or ignores
        // magnitude, and pins the `default: return false` branch.
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.double(2.0))
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.double(1.5))
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.string("1"))
        XCTAssertNotEqual(JSONValue.bool(true), JSONValue.int(1))
    }

    /// int/double cross-equality must stay TRANSITIVE past 2^53, where distinct Ints
    /// round to the same Double. `.int(2^53+1)` must not equal `.double(2^53)` (a lossy
    /// round), otherwise `a==b, b==c, a!=c` and Set/Dictionary membership goes
    /// order-dependent. Kills a `Double(a) == b` that ignores exact representability.
    func testNumericEqualityStaysTransitiveBeyond2To53() {
        let a = JSONValue.int(9_007_199_254_740_993)     // 2^53 + 1, not exactly a Double
        let b = JSONValue.double(9_007_199_254_740_992)  // 2^53
        let c = JSONValue.int(9_007_199_254_740_992)     // 2^53, exactly a Double
        XCTAssertNotEqual(a, b, "a lossy Int must not equal the Double it rounds to")
        XCTAssertEqual(b, c, "an exactly-representable Int still equals its Double")
        XCTAssertNotEqual(a, c)
        // Transitivity holds, so a Set keyed on these keeps a and c distinct.
        XCTAssertEqual(Set<JSONValue>([a, b, c]).count, 2)
    }

    func testEqualNumbersHashEqual() throws {
        let set: Set<JSONValue> = [.int(1), .double(1.0), try WireMockFixture.decode(JSONValue.self, "1")]
        XCTAssertEqual(set.count, 1, "1 and 1.0 must collapse to one element")
    }

    func testIntegerAndDoubleDecodeToExpectedCases() throws {
        guard case .int = try WireMockFixture.decode(JSONValue.self, "42") else { return XCTFail("42 should decode as .int") }
        guard case .double = try WireMockFixture.decode(JSONValue.self, "42.5") else { return XCTFail("42.5 should decode as .double") }
    }

    func testStringAndParsingAccessors() throws {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        // Wrong-case accessors return nil (not a trap).
        XCTAssertNil(JSONValue.int(1).arrayValue)
        XCTAssertNil(JSONValue.int(1).objectValue)
        XCTAssertEqual(([1, 2] as JSONValue).arrayValue?.count, 2)
        XCTAssertEqual(JSONValue(parsing: #"{"a":1}"#)?.objectValue?["a"], .int(1))
        XCTAssertNil(JSONValue(parsing: "{not json"))
    }

    func testOrdinaryValuesRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", 2.5], "c": nil]
        XCTAssertEqual(try WireMockFixture.decode(JSONValue.self, WireMockFixture.encode(value)), value)
    }

    func testBigNumberPrecisionIsDocumentedLossy() throws {
        // Documents the known limitation: a >Int64 integer degrades through Double.
        // (Kept as an explicit contract so a future precision fix has a target.)
        let decoded = try WireMockFixture.decode(JSONValue.self, "12345678901234567890")
        guard case .double = decoded else {
            return XCTFail("a >Int64 integer currently decodes as .double")
        }
    }
}
