import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Boundary-value and path-injection tests — the meticulous-manual-QA lens.
///
/// These lock in three hardening fixes:
///   * B4 — a user-supplied scenario/file name is percent-encoded into a single
///     path segment (a `/`, `?`, `#`, space or non-ASCII char can't inject extra
///     segments or bleed into the query/fragment), and an empty name is rejected
///     client-side before any request is sent.
///   * B5 — the failable `init?(scheme:host:port:)` returns nil for an
///     out-of-range port or a blank host rather than producing a client that only
///     fails later at transport.
///   * B6 — journal timestamps decode as `Int64`, so an epoch-millis value far
///     above `Int32.max` round-trips without overflow.
///
/// Reuses `MockURLProtocol` from `ClientUnitTests.swift` (never redefined here).
final class BoundaryTests: XCTestCase {

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

    // MARK: - 1. Path injection is neutralized (B4)

    /// The dangerous inputs and the single, fully-encoded segment each must
    /// collapse to. `pathSegment` percent-encodes everything outside the RFC 3986
    /// unreserved set, so every reserved character — whether it would split the
    /// path (`/`), start a query/fragment (`?`/`#`), be reinterpreted by the server
    /// (`;` → Jetty matrix params, verified live: raw `;` → 404), or just be raw in
    /// the URL (`+ = & , @ %`, space, non-ASCII) — reaches the wire as `%XX`.
    private static let injectionCases: [(name: String, encoded: String)] = [
        ("a/b", "a%2Fb"),             // `/` -> %2F, must NOT split into two segments
        ("../secret", "..%2Fsecret"), // traversal `/` neutralized; `..` stays literal
        ("a?x=1", "a%3Fx%3D1"),       // `?`/`=` -> %3F/%3D, must NOT start a real query
        ("a#f", "a%23f"),             // `#` -> %23, must NOT start a real fragment
        ("a b", "a%20b"),             // space -> %20
        ("café", "caf%C3%A9"),        // non-ASCII UTF-8 percent-encoded
        ("a;b.txt", "a%3Bb.txt"),     // `;` -> %3B, else Jetty truncates at the matrix sep
        ("a+b", "a%2Bb"),             // `+` -> %2B, server-ambiguous in a path otherwise
        ("50%off", "50%25off"),       // literal `%` -> %25, must NOT read as an escape
        ("a=b&c", "a%3Db%26c"),       // `=`/`&` -> %3D/%26, sub-delims neutralized
        ("a,b@c", "a%2Cb%40c")        // `,`/`@` -> %2C/%40
    ]

    func testGetFileNeutralizesPathInjection() throws {
        for injection in Self.injectionCases {
            MockURLProtocol.respondData { _ in (200, Data()) }
            let client = makeClient()
            _ = try client.getFile(named: injection.name)

            let url = try XCTUnwrap(MockURLProtocol.lastRequest?.url,
                                    "no request captured for \(injection.name)")
            let components = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false))

            // The whole endpoint path is intact and ends in exactly one encoded
            // file segment — no extra segments were injected.
            XCTAssertEqual(components.percentEncodedPath,
                           "/__admin/files/\(injection.encoded)",
                           "injected chars must be encoded into one segment for \(injection.name)")
            XCTAssertTrue(components.percentEncodedPath.contains(injection.encoded),
                          "expected encoded token \(injection.encoded) in path for \(injection.name)")
            // A `?`/`#` in the name must NOT have started a real query/fragment.
            XCTAssertNil(components.query,
                         "\(injection.name) must not produce a query")
            XCTAssertNil(components.fragment,
                         "\(injection.name) must not produce a fragment")
            // The endpoint is exactly `.../files/<segment>` — 4 non-empty segments.
            let segments = components.percentEncodedPath
                .split(separator: "/", omittingEmptySubsequences: true)
            XCTAssertEqual(segments.count, 3,
                           "expected __admin / files / <one segment> for \(injection.name)")

            session?.invalidateAndCancel()
            MockURLProtocol.reset()
        }
    }

    func testSetScenarioStateNeutralizesPathInjection() throws {
        for injection in Self.injectionCases {
            MockURLProtocol.respond { _ in (200, "") }
            let client = makeClient()
            try client.setScenarioState(name: injection.name, state: "Started")

            let url = try XCTUnwrap(MockURLProtocol.lastRequest?.url,
                                    "no request captured for \(injection.name)")
            let components = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false))

            // The name sits between `scenarios/` and `/state` as one encoded segment.
            XCTAssertEqual(components.percentEncodedPath,
                           "/__admin/scenarios/\(injection.encoded)/state",
                           "scenario name must be one encoded segment for \(injection.name)")
            XCTAssertNil(components.query, "\(injection.name) must not produce a query")
            XCTAssertNil(components.fragment, "\(injection.name) must not produce a fragment")

            session?.invalidateAndCancel()
            MockURLProtocol.reset()
        }
    }

    /// Assert on the concrete `%2F` (not a raw `/`) for the traversal case: this
    /// is the precise regression a naive interpolation would reintroduce.
    func testSlashIsEncodedNotRaw() throws {
        MockURLProtocol.respondData { _ in (200, Data()) }
        let client = makeClient()
        _ = try client.getFile(named: "a/b")

        let path = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url),
                          resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertTrue(path.contains("%2F"), "the `/` must reach the wire as %2F, got: \(path)")
        XCTAssertFalse(path.contains("files/a/b"),
                       "the `/` must not split into a raw sub-segment, got: \(path)")
    }

    /// The `;` case in isolation: it is the one reserved char with active server
    /// semantics (Jetty reads it as the start of path/matrix parameters and
    /// truncates the segment there). Verified live against WireMock 3.13.2: a file
    /// PUT/GET with a raw `;` 404s, while `%3B` resolves. Pin the encoding so the
    /// regression can't creep back via a laxer allowlist.
    func testSemicolonIsEncodedNotRaw() throws {
        MockURLProtocol.respondData { _ in (200, Data()) }
        let client = makeClient()
        _ = try client.getFile(named: "a;b.txt")

        let path = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url),
                          resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertTrue(path.contains("%3B"), "the `;` must reach the wire as %3B, got: \(path)")
        XCTAssertFalse(path.contains("a;b"),
                       "a raw `;` must not survive into the path, got: \(path)")
    }

    /// Non-ASCII names (CJK, emoji) encode their UTF-8 bytes and round-trip. Asserts
    /// on properties rather than hand-computed hex: the output is pure ASCII, carries
    /// no raw non-ASCII, and decodes back to the exact input.
    func testUnicodeAndEmojiNamesRoundTrip() throws {
        for name in ["日本語", "🎉party", "Ω≈ç"] {
            let encoded = try AdminClient.pathSegment(name)
            XCTAssertTrue(encoded.allSatisfy { $0.isASCII },
                          "encoded segment must be pure ASCII for \(name), got: \(encoded)")
            XCTAssertEqual(encoded.removingPercentEncoding, name,
                           "must decode back to the original for \(name)")
        }
    }

    /// The bare `.` / `..` guard (`AdminClient.pathSegment`) — rejected client-side
    /// with `.invalidArgument`, never sent. (`../secret` in `injectionCases` proves
    /// a `..` *substring* is fine; these prove the standalone segments are refused.)
    func testBareDotSegmentsAreRejectedAndSendNothing() {
        let client = makeClient()
        for bad in [".", ".."] {
            assertInvalidArgument("getFile(named: \"\(bad)\")") { try client.getFile(named: bad) }
            XCTAssertNil(MockURLProtocol.lastRequest, "getFile(\"\(bad)\") must not hit the network")
            assertInvalidArgument("setScenarioState(\"\(bad)\")") {
                try client.setScenarioState(name: bad, state: "x")
            }
            XCTAssertNil(MockURLProtocol.lastRequest, "setScenarioState(\"\(bad)\") must not hit the network")
        }
    }

    // MARK: - 2. Empty name throws .invalidArgument before any network (B4)

    func testEmptyNamesThrowInvalidArgumentAndSendNothing() {
        // No handler installed: if any of these reached the transport the load
        // would still record a lastRequest, which we assert stays nil.
        let client = makeClient()

        assertInvalidArgument("getFile(named:)") { try client.getFile(named: "") }
        XCTAssertNil(MockURLProtocol.lastRequest, "getFile(\"\") must not hit the network")

        assertInvalidArgument("setScenarioState(name:)") {
            try client.setScenarioState(name: "", state: "x")
        }
        XCTAssertNil(MockURLProtocol.lastRequest, "setScenarioState(\"\") must not hit the network")

        assertInvalidArgument("deleteFile(named:)") { try client.deleteFile(named: "") }
        XCTAssertNil(MockURLProtocol.lastRequest, "deleteFile(\"\") must not hit the network")
    }

    private func assertInvalidArgument<T>(_ label: String,
                                          _ body: () throws -> T,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertThrowsError(try body(), label, file: file, line: line) { error in
            guard case WireMockError.invalidArgument = error else {
                return XCTFail("\(label): expected .invalidArgument, got \(error)",
                               file: file, line: line)
            }
        }
    }

    // MARK: - 3. init? validation (B5)

    func testInitRejectsOutOfRangePorts() {
        XCTAssertNil(WireMock(scheme: "http", host: "localhost", port: 0),
                     "port 0 is out of 1...65535")
        XCTAssertNil(WireMock(scheme: "http", host: "localhost", port: -1),
                     "a negative port is out of range")
        XCTAssertNil(WireMock(scheme: "http", host: "localhost", port: 70_000),
                     "port 70000 is above 65535")
    }

    func testInitAcceptsBoundaryPorts() {
        XCTAssertNotNil(WireMock(scheme: "http", host: "localhost", port: 1),
                        "port 1 is the low boundary and must be accepted")
        XCTAssertNotNil(WireMock(scheme: "http", host: "localhost", port: 65_535),
                        "port 65535 is the high boundary and must be accepted")
    }

    func testInitRejectsBlankHosts() {
        XCTAssertNil(WireMock(scheme: "http", host: "", port: 8080),
                     "an empty host must be rejected")
        XCTAssertNil(WireMock(scheme: "http", host: "   ", port: 8080),
                     "a whitespace-only host must be rejected")
    }

    func testInitAcceptsNormalHost() {
        XCTAssertNotNil(WireMock(scheme: "http", host: "localhost", port: 8080),
                        "a normal host/port must produce a client")
    }

    // MARK: - 4. Large epoch timestamps decode without overflow (B6)

    func testLoggedDateDecodesLargeEpochMillis() throws {
        // ~1.75e12 — well above Int32.max (2_147_483_647). A 32-bit field would
        // overflow; Int64 round-trips it exactly.
        let json = #"{"url":"/x","loggedDate":1752566400000}"#
        let logged = try JSONDecoder().decode(LoggedRequest.self, from: Data(json.utf8))
        XCTAssertEqual(logged.loggedDate, 1_752_566_400_000)
        XCTAssertGreaterThan(logged.loggedDate ?? 0, Int64(Int32.max))
    }

    func testSubEventDecodesLargeTimeOffsetNanos() throws {
        let json = #"{"type":"REQUEST_NOT_MATCHED","timeOffsetNanos":9223372036854000}"#
        let event = try JSONDecoder().decode(SubEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.timeOffsetNanos, 9_223_372_036_854_000)
        XCTAssertGreaterThan(event.timeOffsetNanos ?? 0, Int64(Int32.max))
    }

    // MARK: - 5. Large request body is sent verbatim (boundary smoke)

    func testPutFileSendsLargeBodyWithoutTruncation() throws {
        MockURLProtocol.respond { _ in (200, "") }
        let client = makeClient()

        // 2 MB of non-trivial bytes — big enough to catch a truncating buffer,
        // small enough to keep the test fast.
        let size = 2 * 1024 * 1024
        var payload = Data(count: size)
        for i in stride(from: 0, to: size, by: 4096) {
            payload[i] = UInt8(i & 0xFF)
        }

        try client.putFile(named: "big.bin", data: payload)

        XCTAssertEqual(MockURLProtocol.lastBody?.count, size,
                       "the full body must reach the wire with no truncation")
        XCTAssertEqual(MockURLProtocol.lastBody, payload,
                       "the bytes on the wire must be byte-for-byte what was passed")
    }
}
