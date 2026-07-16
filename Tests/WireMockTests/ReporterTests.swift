import XCTest
@testable import WireMock

/// Server-less tests of the reporter seam: that `stubFor` / `verify` / `expect` /
/// `verifyInOrder` route through the injected `WireMockReporter` as named steps,
/// pass along the WireMock-JSON body, run the wrapped work exactly once, and
/// propagate its result and errors unchanged. Driven by `MockAdminTransport`, so
/// they run under the hermetic `muter` command with no live server.
final class ReporterTests: XCTestCase {

    /// Records every step it is asked to wrap, counts body invocations, and still
    /// runs the work (so behaviour is observably unchanged).
    private final class RecordingReporter: WireMockReporter, @unchecked Sendable {
        struct Step { let name: String; let jsonBody: String? }
        private let lock = NSLock()
        private var _steps: [Step] = []
        private var _bodyCalls = 0

        var steps: [Step] { lock.lock(); defer { lock.unlock() }; return _steps }
        var names: [String] { steps.map(\.name) }
        var bodyCalls: Int { lock.lock(); defer { lock.unlock() }; return _bodyCalls }

        func step<T: Sendable>(_ name: String, jsonBody: String?, _ body: @Sendable () throws -> T) throws -> T {
            lock.lock()
            _steps.append(Step(name: name, jsonBody: jsonBody))
            _bodyCalls += 1   // count the invocation even if `body` throws
            lock.unlock()
            return try body()
        }
    }

    // MARK: - Each seam emits one named step with a JSON body

    func testStubForEmitsStep() throws {
        let reporter = RecordingReporter()
        let transport = MockAdminTransport()
        // Enqueue a decodable StubMapping for the `POST /mappings` register call.
        let mapping = post(urlEqualTo("/orders")).willReturn(ok()).build()
        transport.enqueue("mappings", json: try WireMockFixture.encode(mapping))
        let wireMock = transport.client(reporter: reporter)

        try wireMock.stubFor(post(urlEqualTo("/orders")).willReturn(ok()))

        XCTAssertEqual(reporter.names.count, 1)
        XCTAssertTrue(reporter.names[0].hasPrefix("Stub: POST /orders"), reporter.names[0])
        // The JSON body is the WireMock-style stub description, so it parses as JSON.
        let body = try XCTUnwrap(reporter.steps[0].jsonBody)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    func testVerifyEmitsStep() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport().enqueueCount(1).client(reporter: reporter)

        try wireMock.verify(getRequestedFor(anyUrl))

        XCTAssertEqual(reporter.names.count, 1)
        XCTAssertTrue(reporter.names[0].hasPrefix("Verify ("), reporter.names[0])
        XCTAssertTrue(reporter.names[0].contains("GET"), reporter.names[0])
        XCTAssertNotNil(reporter.steps[0].jsonBody)
    }

    func testExpectToHaveBeenSentEmitsStep() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport().enqueueCount(1).client(reporter: reporter)

        _ = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).toHaveBeenSent(.once)

        XCTAssertTrue(reporter.names.contains { $0.hasPrefix("Verify sent") }, "\(reporter.names)")
    }

    func testExpectSingleTerminalEmitsStep() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/orders","method":"POST"}]"#)
            .client(reporter: reporter)

        _ = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).single()

        XCTAssertTrue(reporter.names.contains { $0.hasPrefix("Capture request: POST /orders") }, "\(reporter.names)")
    }

    func testVerifyInOrderEmitsOneStep() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/a","method":"GET","loggedDate":1}]"#)
            .enqueueFind(rawRequests: #"[{"url":"/b","method":"GET","loggedDate":2}]"#)
            .client(reporter: reporter)

        try wireMock.verifyInOrder([getRequestedFor(urlPathEqualTo("/a")),
                                    getRequestedFor(urlPathEqualTo("/b"))])

        XCTAssertEqual(reporter.names.count, 1)
        XCTAssertTrue(reporter.names[0].hasPrefix("Verify in order (2)"), reporter.names[0])
    }

    // MARK: - Wrapping does not change behaviour

    /// On a failing assertion the wrapped body runs exactly once and its error
    /// propagates through the reporter unchanged.
    func testWrappedBodyRunsOnceAndPropagatesError() {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueCount(0)          // exactly-1 expected, 0 present → throws
            .enqueueNoNearMisses()
            .client(reporter: reporter)

        XCTAssertThrowsError(try wireMock.verify(1, getRequestedFor(anyUrl))) { error in
            XCTAssertTrue(error is VerificationError, "\(error)")
        }
        XCTAssertEqual(reporter.bodyCalls, 1, "body must run exactly once")
        XCTAssertEqual(reporter.names.count, 1)
    }

    /// The default (`NoopReporter`) client behaves exactly as before — the seam is
    /// transparent when no reporter is injected.
    func testDefaultReporterIsTransparent() {
        let wireMock = MockAdminTransport().enqueueCount(1).client()
        XCTAssertNoThrow(try wireMock.verify(getRequestedFor(anyUrl)))
    }

    /// The real `XCTActivityReporter` runs the wrapped work through
    /// `XCTContext.runActivity` on the test's main thread (via `assumeIsolated`)
    /// without crashing, and hands back the wrapped result — an end-to-end check of
    /// the shipped reporter, not just the recording stub.
    func testXCTActivityReporterRunsInline() throws {
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/orders","method":"POST"}]"#)
            .client(reporter: XCTActivityReporter())

        let captured = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).single()
        XCTAssertEqual(captured.url, "/orders")
    }
}
