import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Zero-dependency, property-based tests of the JSON codec layer.
///
/// There is no SwiftCheck here: a small, deterministic PRNG (`SplitMix64`) drives
/// a hand-rolled recursive `JSONValue` generator and a set of model generators,
/// so every run is reproducible. Each property runs a fixed number of iterations
/// from a FIXED seed; on failure the assertion message carries the seed, the
/// iteration index and the offending value so any failure can be replayed.
///
/// The generator's numeric choices are informed by how `JSONValue` decodes on
/// this (Darwin) toolchain — empirically verified while writing these tests:
///   * JSON `true`/`false` decode only as `.bool`; JSON `1`/`0` decode as `.int`.
///   * A whole-valued double (`3.0`) encodes as `3` and decodes back as `.int(3)`
///     — harmless because `JSONValue.==` compares numbers by magnitude.
///   * An integer literal beyond `Int64` overflows `Int` and decodes as `.double`
///     (a documented precision limitation, characterised in one test below).
/// The generator therefore keeps integers inside `Int64` and doubles exactly
/// representable so semantic round-trips hold.
final class PropertyTests: XCTestCase {

    // MARK: - Deterministic PRNG

    /// SplitMix64 — a tiny, fast, well-distributed generator. Seeded with a fixed
    /// constant per property so failures reproduce exactly. Conforms to
    /// `RandomNumberGenerator` so it plugs into `Int.random(in:using:)` etc.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Value generator

    /// Recursive generator for `JSONValue` and the library's model types.
    /// `maxDepth`/`maxWidth` bound the recursion so generation always terminates.
    struct Gen {
        var rng: SplitMix64
        let maxDepth = 4
        let maxWidth = 4

        init(seed: UInt64) { self.rng = SplitMix64(seed: seed) }

        // -- primitives --

        mutating func bool() -> Bool { Bool.random(using: &rng) }

        mutating func int(in range: ClosedRange<Int>) -> Int {
            Int.random(in: range, using: &rng)
        }

        mutating func int(in range: Range<Int>) -> Int {
            Int.random(in: range, using: &rng)
        }

        mutating func oneOf<T>(_ options: [T]) -> T {
            options[Int.random(in: 0 ..< options.count, using: &rng)]
        }

        /// An integer covering zero, negatives, and large-but-in-`Int64` values.
        /// All of these round-trip as `.int` (integers are exact through JSON).
        mutating func anyInt() -> Int {
            switch int(in: 0 ... 9) {
            case 0: return 0
            case 1: return -1
            case 2: return 1
            case 3: return Int(Int32.min)
            case 4: return Int(Int32.max)
            case 5: return 9_007_199_254_740_991      // 2^53 - 1, large but in Int64
            case 6: return -9_007_199_254_740_991
            default: return int(in: -1_000_000_000 ... 1_000_000_000)
            }
        }

        /// A finite double that is exactly representable and therefore round-trips
        /// through JSON without precision drift. Denominators are powers of two,
        /// so `numerator / denominator` is exact in binary64. (Whole results are
        /// fine — they decode as `.int` and compare equal by magnitude.)
        mutating func anyDouble() -> Double {
            let numerator = int(in: -1_000_000 ... 1_000_000)
            let denominator = oneOf([1.0, 2.0, 4.0, 8.0, 16.0])
            return Double(numerator) / denominator
        }

        /// A strictly-positive exactly-representable double (for lognormal params).
        mutating func positiveDouble() -> Double {
            let numerator = int(in: 1 ... 1_000_000)
            let denominator = oneOf([1.0, 2.0, 4.0, 8.0, 16.0])
            return Double(numerator) / denominator
        }

        /// A string drawn from a pool that stresses the encoder: empty, unicode,
        /// emoji, control characters, quotes, backslashes, JSON-looking text.
        mutating func anyString() -> String {
            let pool = [
                "", "a", "hello", "héllo wörld", "🚀 rocket ☃ ⚡",
                "line\nbreak", "tab\there", "quote\"q\"uote", "back\\slash",
                "  padded  ", "0", "1", "true", "false", "null",
                "{\"looks\":\"like json\"}", "[1,2,3]", "/slash/path",
                "\u{0007}\u{001F}control", "мир", "日本語", "a.b.c"
            ]
            return oneOf(pool)
        }

        /// An object key. Duplicate keys collapse in the dictionary, which is fine
        /// — round-trips compare the resulting dictionary, not the draw order.
        mutating func anyKey() -> String {
            oneOf(["k", "key2", "nested", "α", "🔑", "a.b", "", "with space", "0"])
        }

        /// A fully general `JSONValue`, including every case. Below `maxDepth` it
        /// may recurse into arrays/objects; at the cap it emits only scalars.
        mutating func value(depth: Int = 0) -> JSONValue {
            let scalarCount = 5   // null, bool, int, double, string
            let choice = depth >= maxDepth
                ? int(in: 0 ..< scalarCount)          // scalars only at the cap
                : int(in: 0 ..< scalarCount + 2)      // + array + object
            switch choice {
            case 0: return .null
            case 1: return .bool(bool())
            case 2: return .int(anyInt())
            case 3: return .double(anyDouble())
            case 4: return .string(anyString())
            case 5:
                let count = int(in: 0 ... maxWidth)
                return .array((0 ..< count).map { _ in value(depth: depth + 1) })
            default:
                let count = int(in: 0 ... maxWidth)
                var object: [String: JSONValue] = [:]
                for _ in 0 ..< count { object[anyKey()] = value(depth: depth + 1) }
                return .object(object)
            }
        }

        /// Like `value(depth:)` but never emits `.null`. Used where a generated
        /// `JSONValue` is embedded in a model whose *unset optionals* we then
        /// assert are omitted — a real null inside a payload would be legitimate
        /// and would defeat that assertion.
        mutating func valueNoNull(depth: Int = 0) -> JSONValue {
            let choice = depth >= maxDepth ? int(in: 0 ..< 4) : int(in: 0 ..< 6)
            switch choice {
            case 0: return .bool(bool())
            case 1: return .int(anyInt())
            case 2: return .double(anyDouble())
            case 3: return .string(anyString())
            case 4:
                let count = int(in: 0 ... maxWidth)
                return .array((0 ..< count).map { _ in valueNoNull(depth: depth + 1) })
            default:
                let count = int(in: 0 ... maxWidth)
                var object: [String: JSONValue] = [:]
                for _ in 0 ..< count { object[anyKey()] = valueNoNull(depth: depth + 1) }
                return .object(object)
            }
        }

        // -- model generators --

        static let httpMethods: [HTTPMethod] =
            [.get, .post, .put, .patch, .delete, .head, .options, .trace, .getOrHead, .any]

        /// A `StringValuePattern`. `freeform` allows matchers that embed an
        /// arbitrary `JSONValue` (`equalToJson`) and recursive combinators; when
        /// `false` only null-free, flat matchers are produced.
        mutating func stringValuePattern(freeform: Bool, depth: Int = 0) -> StringValuePattern {
            // Choose a flat matcher unless freeform allows a richer one and we
            // still have depth budget.
            if !freeform || depth >= maxDepth || bool() {
                return flatStringValuePattern()
            }
            switch int(in: 0 ... 3) {
            case 0:
                return .equalToJson(valueNoNull(depth: depth + 1),
                                    ignoreArrayOrder: bool(),
                                    ignoreExtraElements: bool())
            case 1:
                let count = int(in: 1 ... 3)
                return .and((0 ..< count).map { _ in stringValuePattern(freeform: false, depth: depth + 1) })
            case 2:
                let count = int(in: 1 ... 3)
                return .or((0 ..< count).map { _ in stringValuePattern(freeform: false, depth: depth + 1) })
            default:
                return .not(stringValuePattern(freeform: false, depth: depth + 1))
            }
        }

        /// A flat (non-recursive, null-free) matcher chosen from the typed factories.
        private mutating func flatStringValuePattern() -> StringValuePattern {
            switch int(in: 0 ... 14) {
            case 0: return .equalTo(anyString())
            case 1: return .equalTo(anyString(), caseInsensitive: true)
            case 2: return .containing(anyString())
            case 3: return .notContaining(anyString())
            case 4: return .matching("[a-z]+")
            case 5: return .notMatching("[0-9]+")
            case 6: return .binaryEqualTo(Data(anyString().utf8).base64EncodedString())
            case 7: return .matchingJsonPath("$.name")
            case 8: return .equalToXml("<a>x</a>")
            case 9: return .matchingXPath("/a/b")
            case 10: return .before("2030-01-01T00:00:00Z")
            case 11: return .after("2020-01-01T00:00:00Z")
            case 12: return .equalToDateTime("now")
            case 13: return .absent
            default: return .anything
            }
        }

        mutating func matcherMap(freeform: Bool) -> [String: StringValuePattern] {
            let count = int(in: 1 ... maxWidth)
            var map: [String: StringValuePattern] = [:]
            for _ in 0 ..< count { map[anyKey()] = stringValuePattern(freeform: freeform) }
            return map
        }

        mutating func headerValue() -> HeaderValue {
            if bool() { return .single(anyString()) }
            let count = int(in: 1 ... 3)
            return .multiple((0 ..< count).map { _ in anyString() })
        }

        mutating func headerMap() -> [String: HeaderValue] {
            let count = int(in: 1 ... maxWidth)
            var map: [String: HeaderValue] = [:]
            for _ in 0 ..< count { map["H-\(anyKey())"] = headerValue() }
            return map
        }

        mutating func delayDistribution() -> DelayDistribution {
            if bool() {
                return .uniform(lower: int(in: 0 ... 100), upper: int(in: 100 ... 500))
            }
            let maxValue: Double? = bool() ? positiveDouble() : nil
            return .lognormal(median: positiveDouble(), sigma: positiveDouble(), maxValue: maxValue)
        }

        mutating func fault() -> Fault {
            let faults: [Fault] = [.emptyResponse, .malformedResponseChunk, .randomDataThenClose, .connectionResetByPeer]
            return oneOf(faults)
        }

        /// A `ResponseDefinition` with a random subset of fields set. When
        /// `freeform` is false, the free-form `JSONValue` fields (which could hold
        /// a legitimate null) are left unset.
        mutating func responseDefinition(freeform: Bool) -> ResponseDefinition {
            var response = ResponseDefinition()
            if bool() { response.status = oneOf([200, 201, 204, 301, 400, 404, 418, 500, 503]) }
            if bool() { response.statusMessage = anyString() }
            if bool() { response.body = anyString() }
            if freeform, bool() { response.jsonBody = valueNoNull(depth: 1) }
            if bool() { response.base64Body = Data(anyString().utf8).base64EncodedString() }
            if bool() { response.bodyFileName = "body-\(int(in: 0 ... 9)).json" }
            if bool() { response.headers = headerMap() }
            if bool() { response.fixedDelayMilliseconds = int(in: 0 ... 5_000) }
            if bool() { response.delayDistribution = delayDistribution() }
            if bool() { response.chunkedDribbleDelay = ChunkedDribbleDelay(numberOfChunks: int(in: 1 ... 10), totalDuration: int(in: 10 ... 1_000)) }
            if bool() { response.fault = fault() }
            if bool() { response.transformers = ["response-template"] }
            if freeform, bool() {
                var params: [String: JSONValue] = [:]
                for _ in 0 ..< int(in: 1 ... 3) { params[anyKey()] = valueNoNull(depth: 1) }
                response.transformerParameters = params
            }
            if bool() { response.proxyBaseUrl = "http://backend.example" }
            if bool() { response.removeProxyRequestHeaders = ["X-Drop"] }
            if bool() { response.proxyUrlPrefixToRemove = "/prefix" }
            return response
        }

        /// A `RequestPattern` with a random subset of fields set.
        mutating func requestPattern(freeform: Bool) -> RequestPattern {
            var request = RequestPattern()
            if bool() { request.method = oneOf(Gen.httpMethods) }
            switch int(in: 0 ... 5) {
            case 0: request.url = "/a/\(int(in: 0 ... 99))"
            case 1: request.urlPattern = "/a/.*"
            case 2: request.urlPath = "/a/b"
            case 3: request.urlPathPattern = "/a/.*"
            case 4: request.urlPathTemplate = "/a/{id}"
            default: break   // no URL form at all is legal
            }
            if bool() { request.headers = matcherMap(freeform: freeform) }
            if bool() { request.queryParameters = matcherMap(freeform: freeform) }
            if bool() { request.cookies = matcherMap(freeform: freeform) }
            if bool() { request.pathParameters = matcherMap(freeform: freeform) }
            if bool() { request.formParameters = matcherMap(freeform: freeform) }
            if bool() {
                let count = int(in: 1 ... 3)
                request.bodyPatterns = (0 ..< count).map { _ in stringValuePattern(freeform: freeform) }
            }
            if bool() { request.host = stringValuePattern(freeform: false) }
            if bool() { request.port = int(in: 1 ... 65_535) }
            if bool() { request.scheme = oneOf(["http", "https"]) }
            if bool() { request.clientIp = .equalTo("10.0.0.\(int(in: 0 ... 255))") }
            if bool() { request.basicAuthCredentials = BasicAuthCredentials(username: anyString(), password: anyString()) }
            return request
        }
    }

    // MARK: - Codec helpers

    /// Encode any `Encodable` and re-read it as a `JSONValue` (mirrors
    /// `GoldenEncodingTests.json`).
    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func decodeValue(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Fixed seeds (one per property, so failures replay independently)

    private static let roundTripSeed: UInt64      = 0x0000_0000_DEAD_BEEF
    private static let idempotentSeed: UInt64     = 0x1234_5678_9ABC_DEF0
    private static let parsingSeed: UInt64        = 0x0F0F_0F0F_0F0F_0F0F
    private static let omittedNullSeed: UInt64    = 0xCAFE_F00D_1357_9BDF
    private static let modelSeed: UInt64          = 0xA5A5_5A5A_C3C3_3C3C

    private let iterations = 300

    // MARK: - Property: JSONValue round-trips through Codable

    func testJSONValueRoundTrip() throws {
        var gen = Gen(seed: Self.roundTripSeed)
        for i in 0 ..< iterations {
            let value = gen.value()
            let data = try JSONEncoder().encode(value)
            let decoded = try decodeValue(data)
            XCTAssertEqual(decoded, value,
                           "round-trip mismatch (seed=\(Self.roundTripSeed) iter=\(i)) value=\(value) decoded=\(decoded)")
        }
    }

    // MARK: - Property: encoding is idempotent once normalised

    /// The first encode/decode normalises numbers (a whole double becomes `.int`).
    /// Re-encoding that normalised value with sorted keys must produce byte-for-byte
    /// identical data — the value is a fixpoint. We also assert the decoded values
    /// are equal, which is the safer/looser guarantee.
    func testReEncodeIsIdempotent() throws {
        var gen = Gen(seed: Self.idempotentSeed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for i in 0 ..< iterations {
            let value = gen.value()
            let firstData = try encoder.encode(value)
            let normalized = try decodeValue(firstData)

            let secondData = try encoder.encode(normalized)
            let reNormalized = try decodeValue(secondData)
            let thirdData = try encoder.encode(reNormalized)

            XCTAssertEqual(normalized, reNormalized,
                           "idempotence value mismatch (seed=\(Self.idempotentSeed) iter=\(i)) value=\(value)")
            XCTAssertEqual(secondData, thirdData,
                           "idempotence byte mismatch (seed=\(Self.idempotentSeed) iter=\(i)) value=\(value)")
        }
    }

    // MARK: - Property: `init?(parsing:)` round-trips `.description`

    /// `JSONValue.description` renders compact JSON (via `JSONSerialization` with
    /// `.fragmentsAllowed`), and `JSONValue(parsing:)` reads it back. This holds
    /// for object, array AND scalar roots on this toolchain — empirically verified
    /// while authoring these tests: `JSONDecoder` here decodes top-level fragments
    /// (`"x"`, `1`, `true`, `null`), so a bare-scalar root round-trips too.
    func testDescriptionParsesBack() throws {
        var gen = Gen(seed: Self.parsingSeed)
        for i in 0 ..< iterations {
            let value = gen.value()
            let text = value.description
            let parsed = JSONValue(parsing: text)
            XCTAssertNotNil(parsed,
                            "description did not parse (seed=\(Self.parsingSeed) iter=\(i)) text=\(text) value=\(value)")
            XCTAssertEqual(parsed, value,
                           "parse round-trip mismatch (seed=\(Self.parsingSeed) iter=\(i)) text=\(text) value=\(value)")
        }
    }

    // MARK: - Property: unset optionals are omitted, never encoded as null

    func testUnsetOptionalsAreOmittedNotNull() throws {
        var gen = Gen(seed: Self.omittedNullSeed)
        for i in 0 ..< iterations {
            // freeform: false → no arbitrary JSONValue payloads, so ANY null found
            // must be an unset optional wrongly serialised (the bug we guard).
            let response = gen.responseDefinition(freeform: false)
            let request = gen.requestPattern(freeform: false)
            let stub = StubMapping(
                id: gen.bool() ? UUID() : nil,
                name: gen.bool() ? gen.anyString() : nil,
                priority: gen.bool() ? gen.int(in: 1 ... 10) : nil,
                request: request,
                response: response,
                persistent: gen.bool() ? gen.bool() : nil
            )
            let encoded = try jsonValue(stub)
            assertNoNull(encoded, seed: Self.omittedNullSeed, iteration: i, path: "$")
        }
    }

    /// Recursively fails if `value` contains any `.null`, reporting the JSON path.
    private func assertNoNull(_ value: JSONValue, seed: UInt64, iteration: Int, path: String) {
        switch value {
        case .null:
            XCTFail("found null at \(path) (seed=\(seed) iter=\(iteration)) — an unset optional must be omitted, not encoded as null")
        case .array(let items):
            for (index, item) in items.enumerated() {
                assertNoNull(item, seed: seed, iteration: iteration, path: "\(path)[\(index)]")
            }
        case .object(let object):
            for (key, child) in object {
                assertNoNull(child, seed: seed, iteration: iteration, path: "\(path).\(key)")
            }
        default:
            break
        }
    }

    // MARK: - Property: models round-trip through Codable

    func testStringValuePatternRoundTrip() throws {
        var gen = Gen(seed: Self.modelSeed)
        for i in 0 ..< iterations {
            let pattern = gen.stringValuePattern(freeform: true)
            let first = try jsonValue(pattern)
            let decoded = try JSONDecoder().decode(StringValuePattern.self, from: JSONEncoder().encode(pattern))
            let second = try jsonValue(decoded)
            XCTAssertEqual(first, second,
                           "StringValuePattern round-trip mismatch (seed=\(Self.modelSeed) iter=\(i)) first=\(first) second=\(second)")
        }
    }

    func testResponseDefinitionRoundTrip() throws {
        var gen = Gen(seed: Self.modelSeed &+ 1)
        for i in 0 ..< iterations {
            let response = gen.responseDefinition(freeform: true)
            let first = try jsonValue(response)
            let decoded = try JSONDecoder().decode(ResponseDefinition.self, from: JSONEncoder().encode(response))
            let second = try jsonValue(decoded)
            XCTAssertEqual(first, second,
                           "ResponseDefinition round-trip mismatch (seed=\(Self.modelSeed &+ 1) iter=\(i)) first=\(first) second=\(second)")
        }
    }

    func testRequestPatternRoundTrip() throws {
        var gen = Gen(seed: Self.modelSeed &+ 2)
        for i in 0 ..< iterations {
            let request = gen.requestPattern(freeform: true)
            let first = try jsonValue(request)
            let decoded = try JSONDecoder().decode(RequestPattern.self, from: JSONEncoder().encode(request))
            let second = try jsonValue(decoded)
            XCTAssertEqual(first, second,
                           "RequestPattern round-trip mismatch (seed=\(Self.modelSeed &+ 2) iter=\(i)) first=\(first) second=\(second)")
        }
    }

    func testStubMappingRoundTrip() throws {
        var gen = Gen(seed: Self.modelSeed &+ 3)
        for i in 0 ..< iterations {
            let stub = StubMapping(
                id: gen.bool() ? UUID() : nil,
                name: gen.bool() ? gen.anyString() : nil,
                priority: gen.bool() ? gen.int(in: 1 ... 10) : nil,
                request: gen.requestPattern(freeform: true),
                response: gen.responseDefinition(freeform: true),
                metadata: gen.bool() ? ["k": gen.valueNoNull(depth: 1)] : nil,
                persistent: gen.bool() ? gen.bool() : nil
            )
            let first = try jsonValue(stub)
            let decoded = try JSONDecoder().decode(StubMapping.self, from: JSONEncoder().encode(stub))
            let second = try jsonValue(decoded)
            XCTAssertEqual(first, second,
                           "StubMapping round-trip mismatch (seed=\(Self.modelSeed &+ 3) iter=\(i)) first=\(first) second=\(second)")
        }
    }

    // MARK: - Characterisation: integer beyond Int64 becomes .double

    /// Documented precision limitation (not a failure): a JSON integer literal that
    /// overflows `Int64` cannot decode as `.int`, so `JSONValue` falls through to
    /// `.double`. Pinned here so the behaviour is intentional and visible.
    func testIntegerBeyondInt64BecomesDouble() throws {
        let parsed = JSONValue(parsing: "99999999999999999999999999")
        guard case .double = parsed else {
            return XCTFail("expected an out-of-Int64 integer literal to decode as .double, got \(String(describing: parsed))")
        }
    }
}
