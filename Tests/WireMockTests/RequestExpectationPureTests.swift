import XCTest
@testable import WireMock

/// Pure-unit tests for the `expect(...)` layer — no server required. These pin the
/// deterministic building blocks (JSONPath parser, captured-request accessors,
/// matcher shapes, count logic, error rendering) that integration tests only
/// exercise indirectly.
final class RequestExpectationPureTests: XCTestCase {

    /// Builds a `CapturedRequest` from a raw journal-shaped JSON object. The JSON
    /// is a compile-time literal, so a decode failure is a test bug — trap loudly
    /// rather than thread `throws` through every caller (and satisfy `force_try`).
    private func captured(_ json: String) -> CapturedRequest {
        guard let logged = try? JSONDecoder().decode(LoggedRequest.self, from: Data(json.utf8)) else {
            fatalError("invalid fixture JSON: \(json)")
        }
        return CapturedRequest(logged: logged)
    }

    // MARK: - JSONPathLite

    private let sample: JSONValue = [
        "id": "ord_42",
        "items": [["sku": "ABC"], ["sku": "DEF"]],
        "nested": ["a": ["b": 7]]
    ]

    func testJSONPathHappyShapes() throws {
        XCTAssertEqual(try JSONPathLite.evaluate("$.id", on: sample).stringValue, "ord_42")
        XCTAssertEqual(try JSONPathLite.evaluate("$.items[1].sku", on: sample).stringValue, "DEF")
        XCTAssertEqual(try JSONPathLite.evaluate("items[0].sku", on: sample).stringValue, "ABC")     // leading segment, no dot
        XCTAssertEqual(try JSONPathLite.evaluate("$['nested'].a.b", on: sample), .int(7))            // single-quoted key
        XCTAssertEqual(try JSONPathLite.evaluate("$[\"nested\"].a.b", on: sample), .int(7))          // double-quoted key
        XCTAssertEqual(try JSONPathLite.evaluate("$['nested']['a']['b']", on: sample), .int(7))      // chained bracket keys
        XCTAssertEqual(try JSONPathLite.evaluate("$", on: sample), sample)                           // bare root
        XCTAssertEqual(try JSONPathLite.evaluate("", on: sample), sample)                            // empty path == root
    }

    func testJSONPathWhitespaceInBrackets() throws {
        XCTAssertEqual(try JSONPathLite.evaluate("$.items[ 1 ].sku", on: sample).stringValue, "DEF")
        XCTAssertEqual(try JSONPathLite.evaluate("$[ 'nested' ].a.b", on: sample), .int(7))
    }

    func testJSONPathRootArrayIndex() throws {
        let arr: JSONValue = ["a", "b", "c"]
        XCTAssertEqual(try JSONPathLite.evaluate("$[0]", on: arr).stringValue, "a")
        XCTAssertEqual(try JSONPathLite.evaluate("[2]", on: arr).stringValue, "c")
    }

    func testJSONPathQuotedNumericAndDottedKeys() throws {
        let obj: JSONValue = ["0": "zero", "a.b": "dotted", "list": ["x", "y"]]
        XCTAssertEqual(try JSONPathLite.evaluate("$['0']", on: obj).stringValue, "zero")     // quoted digits == key
        XCTAssertEqual(try JSONPathLite.evaluate("$[\"0\"]", on: obj).stringValue, "zero")
        XCTAssertEqual(try JSONPathLite.evaluate("$.list[0]", on: obj).stringValue, "x")     // unquoted == index
        XCTAssertEqual(try JSONPathLite.evaluate("$['a.b']", on: obj).stringValue, "dotted") // quotes protect the dot
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.a.b", on: obj))                    // dot splits -> key "a" missing
        // Unquoted, non-numeric bracket content on an object is treated as a KEY
        // (success path of the `else` rung, previously only hit as a failure).
        XCTAssertEqual(try JSONPathLite.evaluate("$[list][1]", on: obj).stringValue, "y")
    }

    /// A bracket key with only a LEADING quote (no matching closing quote) is not
    /// "quoted" — it is a literal key that keeps the quote char. Pins the two
    /// `hasPrefix && hasSuffix` conjunctions: flipping either `&&` to `||` would
    /// misclassify these as quoted and strip a character, so these kill those mutants.
    func testJSONPathHalfQuotedBracketKeyIsLiteral() throws {
        let single: JSONValue = ["'a": 42]           // key literally starts with a quote
        XCTAssertEqual(try JSONPathLite.evaluate("$['a]", on: single), .int(42))
        let double: JSONValue = ["\"a": 43]
        XCTAssertEqual(try JSONPathLite.evaluate("$[\"a]", on: double), .int(43))
        // Trailing-only quote is likewise literal.
        XCTAssertEqual(try JSONPathLite.evaluate("$[a']", on: ["a'": 44]), .int(44))
    }

    func testJSONPathErrorEdges() {
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.missing", on: sample))         // key not found
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[9]", on: sample))        // index out of range
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[-1]", on: sample))       // no negative index
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.", on: sample))                // empty segment
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.nested.a.", on: sample))       // trailing dot
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[", on: sample))          // unterminated '['
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[*]", on: sample))        // wildcard unsupported
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items[0:2]", on: sample))      // slice unsupported
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.id[0]", on: sample))           // index into scalar
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.items.foo", on: sample))       // key into array
        XCTAssertThrowsError(try JSONPathLite.evaluate("$.nested.a.b[0]", on: sample))   // index into number
    }

    /// Pin the DISTINCT error-message kinds, not just "some error" — a mutant that
    /// swaps "key not found" for "index out of range" (or drops the offending key)
    /// would otherwise survive.
    func testJSONPathErrorMessagesAreSpecific() {
        func message(_ path: String) -> String {
            do {
                _ = try JSONPathLite.evaluate(path, on: sample)
                return "<no error>"
            } catch {
                return String(describing: error)
            }
        }
        XCTAssertTrue(message("$.missing").contains("key 'missing' not found"), message("$.missing"))
        XCTAssertTrue(message("$.items[9]").contains("index 9 out of range"), message("$.items[9]"))
        XCTAssertTrue(message("$.items[").contains("unterminated '['"), message("$.items["))
        XCTAssertTrue(message("$.").contains("empty segment"), message("$."))
    }

    // MARK: - CapturedRequest: headers

    func testHeaderCaseInsensitiveAndMultiValue() {
        let request = captured(#"{"headers": {"Content-Type": "application/json", "Accept": ["a", "b"]}}"#)
        XCTAssertEqual(request.header("content-type"), "application/json")   // case-insensitive name
        XCTAssertEqual(request.header("CONTENT-TYPE"), "application/json")
        XCTAssertEqual(request.headers("Content-Type"), ["application/json"])
        XCTAssertEqual(request.headers("accept"), ["a", "b"])               // multi-value
        XCTAssertEqual(request.header("accept"), "a")
        XCTAssertNil(request.header("X-None"))
        XCTAssertEqual(request.headers("X-None"), [])
    }

    // MARK: - CapturedRequest: cookies

    func testCookieSingleMultipleAbsentAndCaseSensitive() {
        let request = captured(#"{"cookies": {"sid": "abc", "multi": ["x", "y"], "Session": "1"}}"#)
        XCTAssertEqual(request.cookie("sid"), "abc")
        XCTAssertEqual(request.cookie("multi"), "x")               // first of multiple
        XCTAssertNil(request.cookie("none"))
        XCTAssertEqual(request.cookie("Session"), "1")
        XCTAssertNil(request.cookie("session"))                    // case-SENSITIVE, unlike headers
    }

    // MARK: - CapturedRequest: query parsing / encoding

    func testQueryParamEncodingAndEdges() {
        XCTAssertEqual(captured(#"{"url": "/s?q=a+b"}"#).queryParam("q"), ["a b"])       // '+' -> space
        XCTAssertEqual(captured(#"{"url": "/s?q=a%2Bb"}"#).queryParam("q"), ["a+b"])     // %2B -> literal '+'
        XCTAssertEqual(captured(#"{"url": "/s?q=a%20b"}"#).queryParam("q"), ["a b"])     // %20 -> space
        XCTAssertEqual(captured(#"{"url": "/s?flag&x=1"}"#).queryParam("flag"), [""])    // valueless -> ""
        XCTAssertEqual(captured(#"{"url": "/s?flag&x=1"}"#).queryParam("x"), ["1"])
        XCTAssertEqual(captured(#"{"url": "/s?tag=a&tag=b"}"#).queryParam("tag"), ["a", "b"]) // repeated key
        XCTAssertEqual(captured(#"{"url": "/s"}"#).queryParam("x"), [])                  // no query string
        XCTAssertTrue(captured(#"{"url": "/s"}"#).queryItems().isEmpty)
        // A literal '=' in the value survives (maxSplits: 1 on the '=' split).
        XCTAssertEqual(captured(#"{"url": "/s?token=a=b"}"#).queryParam("token"), ["a=b"])
        // Empty pairs from leading/doubled '&' are omitted, not decoded as blank items.
        XCTAssertEqual(captured(#"{"url": "/s?&a=1"}"#).queryParam("a"), ["1"])
        XCTAssertEqual(captured(#"{"url": "/s?a=1&&b=2"}"#).queryParam("b"), ["2"])
        XCTAssertEqual(captured(#"{"url": "/s?a=1&&b=2"}"#).queryItems().count, 2)       // not 3 (no empty item)
    }

    // MARK: - bodyJSON / RequestExtractor

    func testBodyJSONNilForNonJSONAndAbsent() {
        XCTAssertNil(captured(#"{"body": "hello world"}"#).bodyJSON)
        let absent = captured("{}")
        XCTAssertNil(absent.bodyJSON)
        XCTAssertNil(absent.bodyString)
    }

    func testBodyJSONScalarFragments() {
        // Pin Foundation's top-level-fragment behavior on the supported platforms.
        XCTAssertEqual(captured(#"{"body": "42"}"#).bodyJSON, .int(42))
        XCTAssertEqual(captured(#"{"body": "true"}"#).bodyJSON, .bool(true))
        XCTAssertEqual(captured(#"{"body": "null"}"#).bodyJSON, .null)
        XCTAssertEqual(captured(##"{"body": "\"x\""}"##).bodyJSON, .string("x"))
    }

    func testExtractorJsonPathThrowsOnNonJSON() {
        let extractor = captured(#"{"body": "nope"}"#).extract()
        XCTAssertThrowsError(try extractor.jsonPath("$.x")) { error in
            XCTAssertTrue(error is RequestExpectationError)
            XCTAssertTrue(String(describing: error).contains("not valid JSON"), String(describing: error))
        }
    }

    func testExtractorJsonPathPropagatesLiteError() {
        let extractor = captured(#"{"body": "{\"id\":1}"}"#).extract()
        XCTAssertEqual(try extractor.jsonPath("$.id"), .int(1))
        XCTAssertThrowsError(try extractor.jsonPath("$.missing"))
    }

    func testExtractorHeaderQueryBody() {
        let request = captured(#"{"url": "/x?token=xyz", "headers": {"X-Trace": "abc"}, "body": "raw"}"#)
        let extractor = request.extract()
        XCTAssertEqual(extractor.header("x-trace"), "abc")
        XCTAssertEqual(extractor.queryParam("token"), "xyz")
        XCTAssertEqual(extractor.body(), "raw")
    }

    // MARK: - CountSpec

    func testCountSpecDescription() {
        XCTAssertEqual(CountSpec.once.description, "exactly 1")
        XCTAssertEqual(CountSpec.never.description, "exactly 0 (never)")
        XCTAssertEqual(CountSpec.times(3).description, "exactly 3")
        XCTAssertEqual(CountSpec.atLeast(2).description, "at least 2")
        XCTAssertEqual(CountSpec.atMost(2).description, "at most 2")
        XCTAssertEqual(CountSpec.moreThan(2).description, "more than 2")
        XCTAssertEqual(CountSpec.lessThan(2).description, "fewer than 2")
        XCTAssertEqual(CountSpec.between(2...5).description, "between 2 and 5")
    }

    func testCountSpecShortfallBoundaries() {
        XCTAssertTrue(CountSpec.once.isShortfall(0))
        XCTAssertFalse(CountSpec.once.isShortfall(2))       // excess, not shortfall
        XCTAssertTrue(CountSpec.atLeast(2).isShortfall(1))
        XCTAssertFalse(CountSpec.atLeast(2).isShortfall(2))
        XCTAssertTrue(CountSpec.moreThan(2).isShortfall(2)) // <= boundary
        XCTAssertFalse(CountSpec.moreThan(2).isShortfall(3))
    }

    // MARK: - Matcher shape (StringValuePattern)

    func testEqualToJsonEmitsFlags() {
        let withFlags = StringValuePattern.equalToJson(["a": 1], ignoreArrayOrder: true, ignoreExtraElements: true)
        XCTAssertEqual(withFlags.fields["ignoreArrayOrder"], .bool(true))
        XCTAssertEqual(withFlags.fields["ignoreExtraElements"], .bool(true))
        let plain = StringValuePattern.equalToJson(["a": 1])
        XCTAssertNil(plain.fields["ignoreArrayOrder"])
        XCTAssertNil(plain.fields["ignoreExtraElements"])
    }

    func testEqualToXmlEmitsOptions() {
        let pattern = StringValuePattern.equalToXml(
            "<a/>", enablePlaceholders: true, ignoreOrderOfSameNode: true, namespaceAwareness: .off
        )
        XCTAssertEqual(pattern.fields["enablePlaceholders"], .bool(true))
        XCTAssertEqual(pattern.fields["ignoreOrderOfSameNode"], .bool(true))
        XCTAssertEqual(pattern.fields["namespaceAwareness"], .string("NONE"))
        XCTAssertNil(StringValuePattern.equalToXml("<a/>").fields["namespaceAwareness"])
    }

    func testMatchingXPathNamespacesShape() {
        let withNs = StringValuePattern.matchingXPath("/a", namespaces: ["ns": "http://x"])
        XCTAssertNotNil(withNs.fields["xPathNamespaces"])
        XCTAssertNil(StringValuePattern.matchingXPath("/a").fields["xPathNamespaces"])
        // Sub-matcher folds into the matchesXPath object with an "expression" key.
        let sub = StringValuePattern.matchingXPath("/a", .equalTo("7"))
        if case .object(let obj)? = sub.fields["matchesXPath"] {
            XCTAssertEqual(obj["expression"], .string("/a"))
            XCTAssertEqual(obj["equalTo"], .string("7"))
        } else {
            XCTFail("expected matchesXPath object, got \(String(describing: sub.fields["matchesXPath"]))")
        }
    }

    func testMatchingJsonSchemaEmitsVersion() {
        XCTAssertEqual(
            StringValuePattern.matchingJsonSchema(["type": "object"], version: .v202012).fields["schemaVersion"],
            .string("V202012")
        )
        XCTAssertNil(StringValuePattern.matchingJsonSchema(["type": "object"]).fields["schemaVersion"])
    }

    func testRawMatcherInvalidJSONThrows() {
        XCTAssertThrowsError(try StringValuePattern.equalToJson(raw: "{bad")) { XCTAssertTrue($0 is WireMockError) }
        XCTAssertThrowsError(try StringValuePattern.matchingJsonSchema(raw: "{bad")) { XCTAssertTrue($0 is WireMockError) }
    }

    // MARK: - Error rendering (compactLine / summary)

    func testCompactLineRendering() throws {
        let longBody = String(repeating: "x", count: 100)
        let line = RequestExpectation.compactLine(
            try WireMockFixture.decode(LoggedRequest.self,
                #"{"method": "POST", "url": "/o", "headers": {"Content-Type": "application/json"}, "body": "\#(longBody)"}"#)
        )
        XCTAssertTrue(line.contains("POST /o"), line)
        XCTAssertTrue(line.contains("Content-Type=application/json"), line)
        XCTAssertTrue(line.contains("…"), line)                        // truncated
        XCTAssertFalse(line.contains(longBody), line)                  // not the full 100 chars

        let empty = RequestExpectation.compactLine(try WireMockFixture.decode(LoggedRequest.self, "{}"))
        XCTAssertEqual(empty, "? ?")                                   // nil method/url, no body= segment

        // Short (<= 80 char) body: the FALSE branch of the truncation ternary —
        // rendered verbatim, no ellipsis.
        let shortLine = RequestExpectation.compactLine(
            try WireMockFixture.decode(LoggedRequest.self, #"{"method": "GET", "url": "/s", "body": "hello"}"#)
        )
        XCTAssertTrue(shortLine.contains("body=hello"), shortLine)
        XCTAssertFalse(shortLine.contains("…"), shortLine)
    }

    func testSummaryFallbacks() {
        // Every rung of the `url ?? urlPattern ?? urlPath ?? urlPathPattern ??
        // urlPathTemplate ?? "any URL"` chain, so a reorder/drop mutant on any rung dies.
        XCTAssertEqual(RequestExpectation.summary(getRequestedFor(urlEqualTo("/e"))), "GET /e")          // url
        XCTAssertEqual(RequestExpectation.summary(getRequestedFor(urlMatching("/x"))), "GET /x")         // urlPattern
        XCTAssertEqual(RequestExpectation.summary(getRequestedFor(urlPathEqualTo("/p"))), "GET /p")      // urlPath
        XCTAssertEqual(RequestExpectation.summary(getRequestedFor(urlPathMatching("/pm.*"))), "GET /pm.*") // urlPathPattern
        XCTAssertEqual(RequestExpectation.summary(getRequestedFor(urlPathTemplate("/t/{id}"))), "GET /t/{id}") // urlPathTemplate
        XCTAssertEqual(RequestExpectation.summary(anyRequestedFor(anyUrl)), "ANY any URL")               // final fallback
    }
}
