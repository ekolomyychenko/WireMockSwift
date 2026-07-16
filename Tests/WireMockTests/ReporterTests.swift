import XCTest
@testable import WireMock

/// Server-less tests of the reporter seam: that `stubFor` / `verify` / `expect` /
/// `verifyInOrder` route through the injected `WireMockReporter` as named steps
/// (right name, right JSON body, right count, right order), run the wrapped work
/// exactly once, and propagate its result and errors unchanged. Driven by
/// `MockAdminTransport`, so they run under the hermetic `muter` command with no
/// live server.
///
/// Not covered here (impossible server-less): the *report-side* output of
/// `XCTActivityReporter` — that the emitted `XCTActivity`/`XCTAttachment` actually
/// land in the `.xcresult` with the right name/content/`.keepAlways`. XCTest has no
/// public API to read back an activity within the same test, so that is asserted by
/// `Scripts/verify-reporter-xcresult.sh` (CI job "Reporter .xcresult guard"), which
/// runs the live reporter test through xcodebuild and inspects the result bundle with
/// `xcresulttool`. Here the real reporter is only checked for being crash-free and
/// behaviour-transparent.
final class ReporterTests: XCTestCase {

    /// Records every step it is asked to wrap, counts body invocations (even when
    /// `body` throws), and still runs the work — so behaviour is observably
    /// unchanged. A class so tests can assert reporter identity across constructors.
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

    /// Parses `body` as a JSON object, failing the test (with `file`/`line`) if it
    /// isn't valid JSON — pins that the attachment payload is real WireMock JSON.
    private func assertJSONObject(_ body: String?, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let body = body ?? ""
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8))
        XCTAssertTrue(object is [String: Any], "jsonBody must be a JSON object. \(message)\n\(body)",
                      file: file, line: line)
    }

    // MARK: - Group 1: step name and JSON body are exact

    func testStubForStepNameAndBody() throws {
        let reporter = RecordingReporter()
        let transport = MockAdminTransport()
        let mapping = post(urlEqualTo("/orders")).willReturn(ok()).build()
        transport.enqueue("mappings", json: try WireMockFixture.encode(mapping))
        let wireMock = transport.client(reporter: reporter)

        let result = try wireMock.stubFor(post(urlEqualTo("/orders")).willReturn(ok()))

        XCTAssertEqual(reporter.names, ["Stub: POST /orders"])
        assertJSONObject(reporter.steps[0].jsonBody)
        XCTAssertTrue(reporter.steps[0].jsonBody!.contains("/orders"), reporter.steps[0].jsonBody!)
        // Transparency: the decoded server mapping is returned unchanged.
        XCTAssertEqual(result.request.url, "/orders")
    }

    func testVerifyStepNameAndBody() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport().enqueueCount(1).client(reporter: reporter)

        try wireMock.verify(getRequestedFor(urlPathEqualTo("/cart")))

        XCTAssertEqual(reporter.names.count, 1)
        XCTAssertTrue(reporter.names[0].hasPrefix("Verify ("), reporter.names[0])
        XCTAssertTrue(reporter.names[0].contains("GET /cart"), reporter.names[0])
        assertJSONObject(reporter.steps[0].jsonBody)
        XCTAssertTrue(reporter.steps[0].jsonBody!.contains("/cart"), reporter.steps[0].jsonBody!)
    }

    /// Both convenience overloads delegate to the single `verify(strategy:_:)`
    /// funnel, so each emits exactly one step (not zero, not two).
    func testVerifyOverloadsEachEmitOneStep() throws {
        let r1 = RecordingReporter()
        try MockAdminTransport().enqueueCount(1).client(reporter: r1)
            .verify(getRequestedFor(anyUrl))
        XCTAssertEqual(r1.names.count, 1, "verify(builder): \(r1.names)")

        let r2 = RecordingReporter()
        try MockAdminTransport().enqueueCount(2).client(reporter: r2)
            .verify(2, getRequestedFor(anyUrl))
        XCTAssertEqual(r2.names.count, 1, "verify(count, builder): \(r2.names)")
    }

    func testToHaveBeenSentStepNames() throws {
        func nameFor(_ apply: (RequestExpectation) throws -> Void, count: Int) rethrows -> [String] {
            let reporter = RecordingReporter()
            let wireMock = MockAdminTransport().enqueueCount(count).client(reporter: reporter)
            try apply(wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))))
            return reporter.names
        }

        XCTAssertEqual(try nameFor({ _ = try $0.toHaveBeenSent(.once) }, count: 1),
                       ["Verify sent (exactly 1): POST /orders"])
        XCTAssertEqual(try nameFor({ _ = try $0.toHaveBeenSentOnce() }, count: 1),
                       ["Verify sent (exactly 1): POST /orders"])
        XCTAssertEqual(try nameFor({ _ = try $0.toNeverHaveBeenSent() }, count: 0),
                       ["Verify sent (exactly 0 (never)): POST /orders"])
    }

    func testTerminalStepNames() throws {
        func nameForTerminal(_ terminal: (RequestExpectation) throws -> Void, find: String) rethrows -> [String] {
            let reporter = RecordingReporter()
            let wireMock = MockAdminTransport().enqueueFind(rawRequests: find).client(reporter: reporter)
            try terminal(wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))))
            return reporter.names
        }
        let one = #"[{"url":"/orders","method":"POST"}]"#
        let two = #"[{"url":"/orders","method":"POST","loggedDate":1},{"url":"/orders","method":"POST","loggedDate":2}]"#

        XCTAssertEqual(try nameForTerminal({ _ = try $0.single() }, find: one),
                       ["Capture request: POST /orders"])
        XCTAssertEqual(try nameForTerminal({ _ = try $0.first() }, find: one),
                       ["Capture first request: POST /orders"])
        XCTAssertEqual(try nameForTerminal({ _ = try $0.last() }, find: one),
                       ["Capture last request: POST /orders"])
        XCTAssertEqual(try nameForTerminal({ _ = try $0.all() }, find: two),
                       ["Capture all requests: POST /orders"])
        // extract() funnels through single() → exactly one "Capture request" step.
        XCTAssertEqual(try nameForTerminal({ _ = try $0.extract() }, find: one),
                       ["Capture request: POST /orders"])
    }

    func testVerifyInOrderStepNameAndBody() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/a","method":"GET","loggedDate":1}]"#)
            .enqueueFind(rawRequests: #"[{"url":"/b","method":"GET","loggedDate":2}]"#)
            .client(reporter: reporter)

        try wireMock.verifyInOrder([getRequestedFor(urlPathEqualTo("/a")),
                                    getRequestedFor(urlPathEqualTo("/b"))])

        XCTAssertEqual(reporter.names, ["Verify in order (2): GET /a → GET /b"])
        let body = try XCTUnwrap(reporter.steps[0].jsonBody)
        XCTAssertTrue(body.contains("/a") && body.contains("/b"), body)
    }

    // MARK: - Group 2: wrapping is behaviour-transparent

    func testSuccessRunsBodyExactlyOnceAndReturnsValue() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/orders","method":"POST"}]"#)
            .client(reporter: reporter)

        let captured = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).single()

        XCTAssertEqual(captured.url, "/orders")
        XCTAssertEqual(reporter.bodyCalls, 1, "body must run exactly once")
    }

    func testAllTerminalReturnsEveryMatch() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/o","method":"POST","loggedDate":1},{"url":"/o","method":"POST","loggedDate":2}]"#)
            .client(reporter: reporter)

        let all = try wireMock.expect(postRequestedFor(urlPathEqualTo("/o"))).all()

        XCTAssertEqual(all.count, 2)
    }

    /// Each seam propagates its native error type through `step`, runs the body
    /// exactly once, and still records the step.
    func testErrorsPropagateThroughStep() {
        // verify shortfall → VerificationError
        let r1 = RecordingReporter()
        let wm1 = MockAdminTransport().enqueueCount(0).enqueueNoNearMisses().client(reporter: r1)
        XCTAssertThrowsError(try wm1.verify(1, getRequestedFor(anyUrl))) { XCTAssertTrue($0 is VerificationError, "\($0)") }
        XCTAssertEqual(r1.bodyCalls, 1)
        XCTAssertEqual(r1.names.count, 1)

        // single() wrong count → RequestExpectationError
        let r2 = RecordingReporter()
        let wm2 = MockAdminTransport().enqueueFind(rawRequests: "[]").client(reporter: r2)
        XCTAssertThrowsError(try wm2.expect(getRequestedFor(anyUrl)).single()) { XCTAssertTrue($0 is RequestExpectationError, "\($0)") }
        XCTAssertEqual(r2.bodyCalls, 1)

        // verifyInOrder out-of-order → SequenceVerificationError
        let r3 = RecordingReporter()
        let wm3 = MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/a","method":"GET"}]"#)                 // undated
            .enqueueFind(rawRequests: #"[{"url":"/b","method":"GET","loggedDate":100}]"#) // dated → no valid order
            .client(reporter: r3)
        XCTAssertThrowsError(
            try wm3.verifyInOrder([getRequestedFor(anyUrl), getRequestedFor(anyUrl)])
        ) { XCTAssertTrue($0 is SequenceVerificationError, "\($0)") }
        XCTAssertEqual(r3.names.count, 1, "the outer in-order step is still recorded")
    }

    /// Field checks (`toHave*`) refine and re-query but are deliberately NOT wrapped
    /// as steps — only the count assertion and terminals are. Pins that design so a
    /// mutant that starts wrapping them is caught.
    func testFieldChecksEmitNoSteps() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport().enqueueCount(1).client(reporter: reporter)

        _ = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders"))).toHaveHeader("X-Trace", equalTo("abc"))

        XCTAssertTrue(reporter.names.isEmpty, "field checks should not emit steps: \(reporter.names)")
    }

    /// A chain emits one step per wrapped call, in call order.
    func testChainEmitsStepsInOrder() throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport()
            .enqueueCount(1)                                          // toHaveBeenSent
            .enqueueFind(rawRequests: #"[{"url":"/orders","method":"POST"}]"#) // single
            .client(reporter: reporter)

        _ = try wireMock.expect(postRequestedFor(urlPathEqualTo("/orders")))
            .toHaveBeenSent(.once)
            .single()

        XCTAssertEqual(reporter.names,
                       ["Verify sent (exactly 1): POST /orders", "Capture request: POST /orders"])
    }

    /// An empty `verifyInOrder` returns before wrapping — no step, no server call.
    func testVerifyInOrderEmptyEmitsNoStep() throws {
        let reporter = RecordingReporter()
        try MockAdminTransport().client(reporter: reporter).verifyInOrder([])
        XCTAssertTrue(reporter.names.isEmpty, "\(reporter.names)")
    }

    /// The default (`NoopReporter`) client behaves exactly as before — the seam is
    /// transparent when no reporter is injected.
    func testDefaultReporterIsTransparent() {
        let wireMock = MockAdminTransport().enqueueCount(1).client()
        XCTAssertNoThrow(try wireMock.verify(getRequestedFor(anyUrl)))
    }

    // MARK: - Group 3: reporter wiring across constructors and async

    /// Every `WireMock` initialiser stores the injected reporter (a mutant dropping
    /// the assignment in any init is caught).
    func testEveryInitStoresTheReporter() throws {
        let base = URL(string: "http://reporter.test")!

        let r1 = RecordingReporter()
        XCTAssertTrue((WireMock(baseURL: base, reporter: r1).reporter as? RecordingReporter) === r1)

        let r2 = RecordingReporter()
        let admin = WireMock(baseURL: base).admin
        XCTAssertTrue((WireMock(admin: admin, reporter: r2).reporter as? RecordingReporter) === r2)

        let r3 = RecordingReporter()
        let scheme = try XCTUnwrap(WireMock(scheme: "http", host: "localhost", port: 8080, reporter: r3))
        XCTAssertTrue((scheme.reporter as? RecordingReporter) === r3)
    }

    /// `callAsync` runs on a background hop with no live test context, so it swaps in
    /// a `NoopReporter` — the wrapped work still succeeds but emits NO steps. Kills a
    /// mutant that removes `disablingReporter()`.
    func testCallAsyncDisablesReporting() async throws {
        let reporter = RecordingReporter()
        let wireMock = MockAdminTransport().enqueueCount(1).client(reporter: reporter)

        try await wireMock.callAsync { try $0.verify(getRequestedFor(anyUrl)) }

        XCTAssertTrue(reporter.names.isEmpty, "callAsync must not emit steps: \(reporter.names)")
    }

    // MARK: - Group 4: the real XCTActivityReporter (hermetic — crash-free & transparent)

    /// The shipped `XCTActivityReporter` runs the wrapped work through
    /// `XCTContext.runActivity` on the test's main thread (via `assumeIsolated`),
    /// with a non-nil `jsonBody` attachment, without crashing — for both a value
    /// terminal and a plain `verify`. (The attachment landing in the `.xcresult` is
    /// asserted by `Scripts/verify-reporter-xcresult.sh`; unobservable server-less.)
    func testXCTActivityReporterRunsInline() throws {
        let captured = try MockAdminTransport()
            .enqueueFind(rawRequests: #"[{"url":"/orders","method":"POST"}]"#)
            .client(reporter: XCTActivityReporter())
            .expect(postRequestedFor(urlPathEqualTo("/orders"))).single()
        XCTAssertEqual(captured.url, "/orders")

        XCTAssertNoThrow(
            try MockAdminTransport().enqueueCount(1)
                .client(reporter: XCTActivityReporter())
                .verify(getRequestedFor(anyUrl))
        )
    }

    /// The real reporter propagates a thrown error out of `runActivity` unchanged
    /// (no swallow, no crash).
    func testXCTActivityReporterPropagatesError() {
        let wireMock = MockAdminTransport()
            .enqueueFind(rawRequests: "[]")
            .client(reporter: XCTActivityReporter())
        XCTAssertThrowsError(try wireMock.expect(getRequestedFor(anyUrl)).single()) {
            XCTAssertTrue($0 is RequestExpectationError, "\($0)")
        }
    }
}
