import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Closes the "golden-only" contract gap: encodings that `GoldenEncodingTests`
/// asserts against hand-authored literals but that were **never POSTed to a real
/// WireMock server**. A wrong-but-internally-consistent encoding passes the golden
/// suite; only a live round-trip proves the server actually accepts and honours it.
///
/// Every test here registers the stub against the real server (a non-2xx makes
/// `stubFor` throw, so acceptance is implicitly asserted) and then exercises the
/// behaviour — a match/miss pair, a status code, a timing bound, or a served body.
final class ContractIntegrationTests: WireMockIntegrationCase {
    private var base: URL { WireMockFixture.baseURL }
    private var port: UInt16 { UInt16(WireMockFixture.baseURL.port ?? 8080) }
    private var host: String { WireMockFixture.baseURL.host ?? "127.0.0.1" }

    // MARK: Response-level lognormal delay (+ maxValue) — was golden-only

    func testResponseLogNormalDelayHonoured() throws {
        // A tight sigma concentrates the distribution around the median, so the
        // lower-bound timing check is a real behavioural proof without flaking.
        try wireMock.stubFor(
            get(urlEqualTo("/lnd")).willReturn(
                ok("lognormal-body").withLogNormalRandomDelay(median: 400, sigma: 0.1, maxValue: 2000)
            )
        )
        let (data, response) = try WireMockFixture.assertTakesAtLeast(0.25) { try WireMockFixture.hit("lnd") }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "lognormal-body")
    }

    // MARK: withGzipDisabled → Content-Encoding: none — was golden-only

    func testGzipDisabledEmitsContentEncodingNone() throws {
        try wireMock.stubFor(get(urlEqualTo("/nogzip")).willReturn(ok("plain").withGzipDisabled()))
        let encodings = try RawHTTP.headerValues("Content-Encoding", path: "/nogzip", host: host, port: port)
        XCTAssertEqual(encodings, ["none"], "server must serve the Content-Encoding: none header, got \(encodings)")
    }

    // MARK: Redirect helpers (301/302/303) + Location — were golden-only

    func testRedirectHelpersServeStatusAndLocation() throws {
        let cases: [(String, ResponseDefinitionBuilder, String)] = [
            ("/perm", permanentRedirect(to: "/moved-perm"), "301"),
            ("/temp", temporaryRedirect(to: "/moved-temp"), "302"),
            ("/see", seeOther(to: "/moved-see"), "303")
        ]
        for (path, builder, code) in cases {
            try wireMock.stubFor(get(urlEqualTo(path)).willReturn(builder))
            // URLSession auto-follows redirects, so read the raw wire instead.
            let statusLine = try RawHTTP.statusLine(path: path, host: host, port: port)
            XCTAssertTrue(statusLine.contains(code), "\(path): expected \(code), status line was: \(statusLine)")
            let location = try RawHTTP.headerValues("Location", path: path, host: host, port: port)
            XCTAssertEqual(location.count, 1, "\(path): expected one Location header, got \(location)")
        }
    }

    // MARK: Response status factories — were golden-only (never served)

    func testStatusFactoriesServeExpectedCodes() throws {
        let cases: [(String, ResponseDefinitionBuilder, Int)] = [
            ("/c", created(), 201), ("/nc", noContent(), 204), ("/br", badRequest(), 400),
            ("/ua", unauthorized(), 401), ("/fb", forbidden(), 403),
            ("/se", serverError(), 500), ("/su", serviceUnavailable(), 503)
        ]
        for (path, builder, code) in cases {
            try wireMock.stubFor(get(urlEqualTo(path)).willReturn(builder))
            let (_, response) = try WireMockFixture.hit(String(path.dropFirst()))
            XCTAssertEqual(response.statusCode, code, "\(path) should serve \(code)")
        }
    }

    // MARK: Legacy postServeActions webhook path — was golden-only

    func testPostServeActionWebhookFires() throws {
        try wireMock.stubFor(post(urlEqualTo("/psa-receiver")).willReturn(ok()))
        // The legacy postServeActions array (distinct from the serveEventListeners
        // path that withWebhook uses) must still drive the built-in webhook.
        try wireMock.stubFor(
            post(urlEqualTo("/psa-fire")).withPostServeAction("webhook", parameters: [
                "method": "POST",
                "url": .string(base.appendingPathComponent("psa-receiver").absoluteString),
                "body": "ping"
            ]).willReturn(ok())
        )
        _ = try WireMockFixture.hit("psa-fire", method: "POST")

        var received = 0
        for _ in 0..<20 {
            received = try wireMock.count(postRequestedFor(urlEqualTo("/psa-receiver")))
            if received >= 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(received, 1, "the legacy postServeActions webhook should have hit /psa-receiver")
    }

    // MARK: Object/submatcher forms of JSONPath & XPath — were golden-only

    func testMatchingJsonPathSubmatcherMatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/jp")).withRequestBody(matchingJsonPath("$.name", containing("bob"))).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("jp", method: "POST", body: Data(#"{"name":"bobby"}"#.utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("jp", method: "POST", body: Data(#"{"name":"alice"}"#.utf8)))
    }

    func testMatchingXPathSubmatcherWithNamespacesMatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/xp"))
                .withRequestBody(.matchingXPath("/t:note/t:to", containing("Bob"), namespaces: ["t": "urn:t"]))
                .willReturn(ok())
        )
        let good = #"<t:note xmlns:t="urn:t"><t:to>Bobby</t:to></t:note>"#
        let bad = #"<t:note xmlns:t="urn:t"><t:to>Alice</t:to></t:note>"#
        WireMockFixture.assertMatch(try WireMockFixture.hit("xp", method: "POST", body: Data(good.utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("xp", method: "POST", body: Data(bad.utf8)))
    }

    // MARK: Date/time matcher with offset + truncation fields — were golden-only

    func testDateTimeOffsetTruncationMatchesLive() throws {
        // The offset/truncation fields are the golden-only part; prove the server
        // accepts them and applies the comparison to a header value.
        try wireMock.stubFor(
            get(urlEqualTo("/dt")).withHeader("X-When", .after(
                "2000-01-01T00:00:00Z",
                truncateExpected: "first day of year",
                expectedOffset: 1,
                expectedOffsetUnit: .days
            )).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("dt", headers: ["X-When": "2024-06-01T00:00:00Z"]))
        WireMockFixture.assertMiss(try WireMockFixture.hit("dt", headers: ["X-When": "1990-01-01T00:00:00Z"]))
    }

    // MARK: Extended equalToXml options — were golden-only

    func testEqualToXmlIgnoreOrderMatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/xml")).withRequestBody(.equalToXml(
                "<root><item>1</item><item>2</item></root>",
                exemptedComparisons: ["NAMESPACE_URI"],
                ignoreOrderOfSameNode: true
            )).willReturn(ok())
        )
        // ignoreOrderOfSameNode ignores the order of siblings with the SAME name,
        // so reordered <item> nodes must still match; different content must not.
        WireMockFixture.assertMatch(try WireMockFixture.hit("xml", method: "POST", body: Data("<root><item>2</item><item>1</item></root>".utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("xml", method: "POST", body: Data("<root><item>9</item></root>".utf8)))
    }

    func testEqualToXmlNamespaceAwarenessOffAccepted() throws {
        // Contract note: with namespaceAwareness NONE the server applies a stricter
        // node comparison (ignoreOrderOfSameNode no longer relaxes sibling order),
        // so this only asserts the field is accepted and matches identical XML.
        try wireMock.stubFor(
            post(urlEqualTo("/xmlns")).withRequestBody(.equalToXml(
                "<root><item>1</item></root>",
                namespaceAwareness: .off
            )).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("xmlns", method: "POST", body: Data("<root><item>1</item></root>".utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("xmlns", method: "POST", body: Data("<root><item>2</item></root>".utf8)))
    }

    // MARK: Non-string (Int) transformer parameter — was golden-only

    func testIntTransformerParameterRendersLive() throws {
        try wireMock.stubFor(
            get(urlEqualTo("/itp")).willReturn(
                ok("count={{parameters.count}}")
                    .withTransformers("response-template")
                    .withTransformerParameter("count", 3)
            )
        )
        let (data, _) = try WireMockFixture.hit("itp")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "count=3")
    }

    // MARK: additionalProxyRequestHeaders — the array form is ACCEPTED but WireMock
    // 3.13.2 only forwards the FIRST value. This pins that real behaviour so the
    // library never quietly claims true multi-value proxy-header injection.

    func testMultiValueProxyHeaderForwardsFirstValueOnly() throws {
        try wireMock.stubFor(get(urlEqualTo("/up-multi")).willReturn(ok("up")))
        try wireMock.stubFor(
            any(urlPathMatching("/gwm/.*")).willReturn(
                aResponse().proxiedFrom(base.absoluteString)
                    .withProxyUrlPrefixToRemove("/gwm")
                    .withAdditionalRequestHeader("X-Multi", ["a", "b"])
            )
        )
        _ = try WireMockFixture.hit("gwm/up-multi")
        let upstream = try XCTUnwrap(try wireMock.findAll(getRequestedFor(urlEqualTo("/up-multi"))).first)
        // Contract fact: only "a" arrives — the array form does not yield two values.
        XCTAssertEqual(upstream.headers?["X-Multi"]?.description, "a",
                       "WireMock 3.13.2 forwards only the first additionalProxyRequestHeaders value")
    }

    // MARK: binaryEqualTo(Data) overload — was golden-only

    func testBinaryEqualToDataMatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/bin")).withRequestBody(binaryEqualTo(Data("hello".utf8))).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("bin", method: "POST", body: Data("hello".utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("bin", method: "POST", body: Data("world".utf8)))
    }

    // MARK: JSON-schema V7 / raw variant — was golden-only

    func testMatchingJsonSchemaV7MatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/schema")).withRequestBody(.matchingJsonSchema(
                raw: #"{"type":"object","required":["id"]}"#, version: .v7
            )).willReturn(ok())
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("schema", method: "POST", body: Data(#"{"id":1}"#.utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("schema", method: "POST", body: Data(#"{}"#.utf8)))
    }

    // MARK: Multipart per-part header matchers — were golden-only

    func testMultipartPartHeaderMatchesLive() throws {
        try wireMock.stubFor(
            post(urlEqualTo("/mp")).withMultipartRequestBody(
                MultipartValuePattern(
                    name: "file",
                    matchingType: .any,
                    headers: ["X-Part": equalTo("keep")],
                    bodyPatterns: [containing("hi")]
                )
            ).willReturn(ok())
        )
        let boundary = "BOUND42"
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        let good = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"\r\nX-Part: keep\r\n\r\nhi there\r\n--\(boundary)--\r\n"
        let bad = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"\r\nX-Part: drop\r\n\r\nhi there\r\n--\(boundary)--\r\n"
        WireMockFixture.assertMatch(try WireMockFixture.hit("mp", method: "POST", headers: headers, body: Data(good.utf8)))
        WireMockFixture.assertMiss(try WireMockFixture.hit("mp", method: "POST", headers: headers, body: Data(bad.utf8)))
    }

    // MARK: persistent() flag — was golden-only; prove server stores & echoes it

    func testPersistentFlagRoundTripsThroughServer() throws {
        let created = try wireMock.stubFor(get(urlEqualTo("/persist")).persistent().willReturn(ok()))
        let id = try XCTUnwrap(created.id)
        let fetched = try wireMock.getStubMapping(id: id)
        XCTAssertEqual(fetched.persistent, true, "the server must store and echo persistent: true")
        // Clean up the persisted mapping so it can't leak onto disk for later runs.
        try wireMock.removeStubMapping(id: id)
    }

    // MARK: RecordSpec filters + ExtractBodyCriteria — were golden-only

    func testSnapshotWithFiltersAndExtractBodyCriteriaAccepted() throws {
        let deadTarget = base.absoluteString + "/nowhere"
        try wireMock.stubFor(get(urlEqualTo("/snapfilter")).willReturn(aResponse().proxiedFrom(deadTarget)))
        _ = try WireMockFixture.hit("snapfilter")

        // The filters (urlPathPattern + method) and extractBodyCriteria fields are
        // golden-only — the server must accept them (no 422) and still snapshot.
        let spec = RecordSpec(
            filters: RecordFilters(urlPathPattern: "/snapfilter", method: .get),
            extractBodyCriteria: ExtractBodyCriteria(textSizeThreshold: "0"),
            persist: false
        )
        let snapshot = try wireMock.takeSnapshot(spec)
        XCTAssertTrue(snapshot.contains { $0.request.url == "/snapfilter" },
                      "filtered snapshot must return the proxied mapping; got \(snapshot.map { $0.request.url })")
    }

    // MARK: Journal-query endpoints accept rich matcher patterns — was implicit-only

    /// The `expect(...)` layer POSTs a `RequestPattern` to `/requests/count` and
    /// `/requests/find`. Until now the server's ACCEPTANCE of a journal query carrying
    /// rich matchers (`cookies` + `formParameters` + `matchesJsonPath`) was only proven
    /// *implicitly* — a 422 would surface as an opaque `expect` failure. This frames it
    /// directly: a pattern with all three fields must be accepted (no throw), and a
    /// matching subset must actually count/find the request end-to-end. If a future
    /// server tightened journal-query deserialization, this goes red as a clear contract
    /// failure, not a mysterious assertion miss.
    func testJournalQueryAcceptsRichMatcherPattern() throws {
        try wireMock.stubFor(post(urlPathEqualTo("/journal-rich")).willReturn(ok()))
        try WireMockFixture.hit(
            "journal-rich", method: "POST",
            headers: ["Content-Type": "application/json", "Cookie": "sid=s1"],
            body: Data(#"{"id":7}"#.utf8)
        )

        // Acceptance: a pattern combining cookies + formParameters + matchesJsonPath must
        // not 422 on the journal-query endpoints. It won't MATCH (no form param on a JSON
        // body), but count/findAll returning at all proves the server accepted the query.
        let richPattern = postRequestedFor(urlPathEqualTo("/journal-rich"))
            .withCookie("sid", equalTo("s1"))
            .withFormParam("grant_type", equalTo("x"))
            .withRequestBody(matchingJsonPath("$.id"))
        XCTAssertNoThrow(try wireMock.count(richPattern), "journal /requests/count must accept the rich pattern")
        XCTAssertNoThrow(try wireMock.findAll(richPattern), "journal /requests/find must accept the rich pattern")

        // End-to-end: a matching subset (cookie + JSONPath value) actually finds the request.
        let matchPattern = postRequestedFor(urlPathEqualTo("/journal-rich"))
            .withCookie("sid", equalTo("s1"))
            .withRequestBody(matchingJsonPath("$.id", equalTo("7")))
        XCTAssertEqual(try wireMock.count(matchPattern), 1, "cookie + JSONPath journal query must match the request")
        XCTAssertEqual(try wireMock.findAll(matchPattern).count, 1)
    }

    // MARK: New WS2 ergonomics — proven live so they aren't golden-only either

    func testGetOrHeadStubMatchesGetAndHeadLive() throws {
        try wireMock.stubFor(getOrHead(urlEqualTo("/goh")).willReturn(ok("goh")))
        WireMockFixture.assertMatch(try WireMockFixture.hit("goh", method: "GET"))
        let (_, headResponse) = try WireMockFixture.hit("goh", method: "HEAD")
        XCTAssertEqual(headResponse.statusCode, 200, "GET_OR_HEAD must also match a HEAD request")
        WireMockFixture.assertMiss(try WireMockFixture.hit("goh", method: "POST"))
    }

    func testBulkHeadersAndQueryParamsMatchLive() throws {
        try wireMock.stubFor(
            get(urlPathEqualTo("/bulk"))
                .withHeaders(["X-A": equalTo("1"), "X-B": containing("z")])
                .withQueryParams(["q1": equalTo("a")])
                .willReturn(ok("bulk"))
        )
        WireMockFixture.assertMatch(try WireMockFixture.hit("bulk?q1=a", headers: ["X-A": "1", "X-B": "zzz"]))
        // Missing one required header → no match.
        WireMockFixture.assertMiss(try WireMockFixture.hit("bulk?q1=a", headers: ["X-A": "1"]))
        // Wrong query value → no match.
        WireMockFixture.assertMiss(try WireMockFixture.hit("bulk?q1=b", headers: ["X-A": "1", "X-B": "zzz"]))
    }

    // MARK: Stub-mapping pagination (limit/offset) — new typed surface

    func testListStubMappingsPagination() throws {
        for i in 0..<3 {
            try wireMock.stubFor(get(urlEqualTo("/pg\(i)")).willReturn(ok()))
        }
        // A page smaller than the total returns exactly the page size...
        XCTAssertEqual(try wireMock.listAllStubMappings(limit: 2).count, 2)
        // ...offset walks past the first page to the remainder...
        XCTAssertEqual(try wireMock.listAllStubMappings(limit: 2, offset: 2).count, 1)
        // ...and the count is the full total, independent of any page size.
        XCTAssertEqual(try wireMock.countStubMappings(), 3)
        // No paging args still returns everything.
        XCTAssertEqual(try wireMock.listAllStubMappings().count, 3)
    }

    // MARK: Templated webhook (transformers) — new typed surface

    /// `transformers: ["response-template"]` must actually run: the outbound
    /// webhook body is a Handlebars template over the original request, so a
    /// green result is behavioural proof the field is honoured, not just accepted.
    func testTemplatedWebhookSubstitutesOriginalRequest() throws {
        try wireMock.stubFor(post(urlEqualTo("/wh-receiver")).willReturn(ok()))
        try wireMock.stubFor(
            post(urlEqualTo("/wh-fire")).willReturn(ok()).withWebhook(
                WebhookDefinition(
                    method: .post,
                    url: base.appendingPathComponent("wh-receiver").absoluteString,
                    body: "templated-{{originalRequest.body}}",
                    transformers: ["response-template"]
                )
            )
        )
        _ = try WireMockFixture.hit("wh-fire", method: "POST", body: Data("bob".utf8))

        // The webhook is asynchronous; poll for the callback and its templated body.
        var body: String?
        for _ in 0..<20 {
            if let first = try wireMock.findAll(postRequestedFor(urlEqualTo("/wh-receiver"))).first {
                body = first.body
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(body, "templated-bob",
                       "response-template transformer must substitute the original request body")
    }

    /// `extraParameters` is a real Java `WebhookDefinition.withExtraParameter`
    /// field; the built-in response-template transformer doesn't surface it (it's
    /// consumed by custom/server-side webhook transformers), so we prove the
    /// contract: the server accepts it and round-trips it on the stored mapping.
    func testWebhookExtraParametersAcceptedAndRoundTripped() throws {
        let created = try wireMock.stubFor(
            post(urlEqualTo("/wh-extra")).willReturn(ok()).withWebhook(
                WebhookDefinition(
                    method: .post,
                    url: base.appendingPathComponent("wh-receiver").absoluteString,
                    body: "x",
                    transformers: ["response-template"],
                    extraParameters: ["greeting": "hi", "count": 3]
                )
            )
        )
        let id = try XCTUnwrap(created.id)
        let listener = try XCTUnwrap(try wireMock.getStubMapping(id: id).serveEventListeners?.first)
        XCTAssertEqual(listener.parameters?["transformers"]?.arrayValue, ["response-template"])
        let extra = try XCTUnwrap(listener.parameters?["extraParameters"]?.objectValue)
        XCTAssertEqual(extra["greeting"], "hi")
        XCTAssertEqual(extra["count"], 3)
    }
}
