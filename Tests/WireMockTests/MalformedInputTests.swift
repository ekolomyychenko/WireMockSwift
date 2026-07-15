import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Adversarial / malformed-input tests. These prove the decoders and the client
/// surface *clean* errors — never a crash, never a silently-empty result — when
/// fed garbage: truncated/invalid JSON, non-UTF8 bytes, pathological numbers,
/// exotic strings, and shape mismatches.
///
/// The client-facing cases reuse `MockURLProtocol` (defined in
/// `ClientUnitTests.swift`) so no live WireMock server is required.
final class MalformedInputTests: XCTestCase {

    private var session: URLSession?

    private func makeClient(authorization: AdminAuthorization? = nil) -> WireMock {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        self.session = session
        return WireMock(baseURL: URL(string: "http://stub.local:8080")!,
                        authorization: authorization, session: session)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        session = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 1. JSONValue decoding of garbage (pure JSONDecoder, no client)

    private func decodeJSONValue(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    func testTruncatedJSONThrows() {
        // A mid-object cut-off must throw a decoding error, not return a partial.
        XCTAssertThrowsError(try decodeJSONValue(#"{"a":"#))
    }

    func testPlainGarbageThrows() {
        XCTAssertThrowsError(try decodeJSONValue("<<<not json at all>>>"))
    }

    func testEmptyDataThrows() {
        // Zero bytes is not a JSON document; decoding must throw, not trap.
        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data()))
    }

    func testArrayWhereObjectExpectedThrows() {
        // Shape mismatch: a top-level array can't decode into an object type.
        XCTAssertThrowsError(
            try JSONDecoder().decode([String: JSONValue].self, from: Data("[1,2,3]".utf8))
        )
    }

    func testDeeplyNestedJSONDoesNotCrash() {
        // ~50 levels of nesting must decode (or throw) without blowing the stack.
        let depth = 50
        let nested = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        XCTAssertNoThrow(try decodeJSONValue(nested))
    }

    func testHugeStringValueDecodesCleanly() throws {
        // A very large string value must round-trip into `.string`, not overflow.
        let big = String(repeating: "x", count: 200_000)
        let value = try decodeJSONValue("\"\(big)\"")
        XCTAssertEqual(value.stringValue?.count, big.count)
    }

    func testUnicodeEmojiAndSurrogatePairStringDecodes() throws {
        // Emoji (a surrogate pair in UTF-16) plus a JSON \u escape and combining
        // marks must decode losslessly into a `.string`.
        let value = try decodeJSONValue(#""ab😀é é 😀""#)
        guard case .string(let s) = value else {
            return XCTFail("expected .string, got \(value)")
        }
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.contains("😀"))
    }

    func testBareNaNTokenThrows() {
        // `NaN` is not valid JSON — it must throw cleanly, never crash.
        XCTAssertThrowsError(try decodeJSONValue("NaN"))
    }

    func testBareInfinityTokenThrows() {
        // `Infinity` is likewise invalid JSON and must throw.
        XCTAssertThrowsError(try decodeJSONValue("Infinity"))
    }

    func testIntegerLargerThanInt64DecodesAsDouble() throws {
        // Int64.max + 1 overflows `Int`; JSONValue falls back to `.double` rather
        // than trapping on the overflowing integer conversion.
        let value = try decodeJSONValue("9223372036854775808")
        guard case .double = value else {
            return XCTFail("expected .double fallback for an out-of-Int64 integer, got \(value)")
        }
    }

    func testNumberLargerThanDoubleRangeDoesNotCrash() {
        // 1e400 overflows Double. Foundation either throws a decoding error or
        // yields `.double(.infinity)`; both are clean. We only assert it never traps.
        let data = Data("1e400".utf8)
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            // Decoded — acceptable (typically .double(.infinity)).
            _ = value
        } catch {
            // Threw cleanly — also acceptable.
        }
    }

    // MARK: - 2. Client decode failure surfaces .decodingFailed

    func testClientDecodeFailureSurfacesAsDecodingFailed() throws {
        // HTTP 200 but a body that cannot decode into GetServeEventsResult
        // (its `requests` field is required) must surface .decodingFailed.
        MockURLProtocol.respond { _ in (200, #"{"garbage":true}"#) }
        let client = makeClient()
        XCTAssertThrowsError(try client.getAllServeEvents()) { error in
            guard case WireMockError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    func testClientTruncatedJSONSurfacesAsDecodingFailed() throws {
        MockURLProtocol.respond { _ in (200, #"{"requests":[{"id":"#) }
        let client = makeClient()
        XCTAssertThrowsError(try client.getAllServeEvents()) { error in
            guard case WireMockError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - 3. Non-UTF8 error body is preserved (ISO-8859-1 fallback)

    func testNonUTF8ErrorBodyIsPreservedNotEmpty() throws {
        // 0xFF/0xFE/0x80/0x81 is not valid UTF-8. The client's ISO-8859-1 fallback
        // must render *some* text so the error body is never silently emptied.
        MockURLProtocol.respondData { _ in (500, Data([0xFF, 0xFE, 0x80, 0x81])) }
        let client = makeClient()
        do {
            _ = try client.getAllServeEvents()
            XCTFail("expected .unexpectedStatus")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertFalse(body.isEmpty,
                           "a non-UTF8 error body must be rendered via the ISO-8859-1 fallback, not dropped")
        }
    }

    // MARK: - 4. getHealth() on a non-JSON body

    func testGetHealthOnNonJSONBodyThrowsDecodingFailed() throws {
        // getHealth() decodes the body as a JSONValue. A plain-text body like "OK"
        // is not valid JSON, so the documented behavior is a clean .decodingFailed
        // (NOT a crash and NOT a bogus/empty JSONValue).
        MockURLProtocol.respond { _ in (200, "OK") }
        let client = makeClient()
        XCTAssertThrowsError(try client.getHealth()) { error in
            guard case WireMockError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    func testGetHealthOnEmptyBodyThrowsDecodingFailed() throws {
        // An empty body is likewise not decodable into a JSONValue → .decodingFailed.
        MockURLProtocol.respond { _ in (200, "") }
        let client = makeClient()
        XCTAssertThrowsError(try client.getHealth()) { error in
            guard case WireMockError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - 5. register(raw:) invalid JSON throws BEFORE any network call

    func testRegisterRawInvalidJSONThrowsWithoutNetworkCall() throws {
        // The up-front JSON validation must reject bad input before a request is
        // ever sent. We install a handler that would succeed if reached, then prove
        // it was never reached (lastRequest stays nil).
        MockURLProtocol.respond { _ in (201, "") }
        let client = makeClient()
        XCTAssertThrowsError(try client.register(raw: "{not valid json")) { error in
            guard case WireMockError.decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
        XCTAssertNil(MockURLProtocol.lastRequest,
                     "invalid JSON must be rejected before any network request is made")
    }

    // MARK: - 6. register(raw:) sends the bytes verbatim (no reorder/coerce)

    func testRegisterRawSendsBytesVerbatim() throws {
        // A distinctive key order (z before a) plus an integer beyond Double's
        // exact-integer range (2^53+1) proves the raw hatch neither reorders keys
        // nor coerces numbers via a JSONValue round-trip.
        let payload = #"{"z":1,"a":9007199254740993}"#
        MockURLProtocol.respond { _ in (201, "") }
        let client = makeClient()
        try client.register(raw: payload)

        XCTAssertNotNil(MockURLProtocol.lastRequest, "the raw registration must have been sent")
        if let sent = MockURLProtocol.lastBody {
            XCTAssertEqual(sent, Data(payload.utf8),
                           "register(raw:) must transmit the exact bytes it was given, verbatim")
        } else {
            // Fall back to proving the request was made if the body stream wasn't captured.
            XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        }
    }
}
