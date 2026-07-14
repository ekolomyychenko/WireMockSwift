import XCTest
@testable import WireMock

/// Verifies that the Swift DSL serialises to exactly the JSON shape the
/// WireMock server expects. Comparison is semantic (decoded into `JSONValue`),
/// so key ordering does not cause flakiness.
final class GoldenEncodingTests: XCTestCase {

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testSimpleGetStub() throws {
        let stub = get(urlEqualTo("/hello")).willReturn(ok("world")).build()
        let expected: JSONValue = [
            "request": ["method": "GET", "url": "/hello"],
            "response": ["status": 200, "body": "world"],
        ]
        XCTAssertEqual(try json(stub), expected)
    }

    func testHeaderAndBodyMatchers() throws {
        let stub = post(urlPathEqualTo("/things"))
            .withHeader("Content-Type", equalTo("application/json"))
            .withRequestBody(matchingJsonPath("$.name"))
            .atPriority(1)
            .willReturn(okForJson(["id": 1]))
            .build()

        let expected: JSONValue = [
            "priority": 1,
            "request": [
                "method": "POST",
                "urlPath": "/things",
                "headers": ["Content-Type": ["equalTo": "application/json"]],
                "bodyPatterns": [["matchesJsonPath": "$.name"]],
            ],
            "response": [
                "status": 200,
                "headers": ["Content-Type": "application/json"],
                "jsonBody": ["id": 1],
            ],
        ]
        XCTAssertEqual(try json(stub), expected)
    }

    func testEqualToJsonFlags() throws {
        let pattern = equalToJson(["a": 1], ignoreArrayOrder: true, ignoreExtraElements: true)
        let expected: JSONValue = [
            "equalToJson": ["a": 1],
            "ignoreArrayOrder": true,
            "ignoreExtraElements": true,
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testLogicalCombinator() throws {
        let pattern = and(containing("foo"), notContaining("bar"))
        let expected: JSONValue = [
            "and": [["contains": "foo"], ["doesNotContain": "bar"]],
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testFaultAndDelay() throws {
        let response = aResponse()
            .withFixedDelay(500)
            .withFault(.connectionResetByPeer)
        let expected: JSONValue = [
            "fixedDelayMilliseconds": 500,
            "fault": "CONNECTION_RESET_BY_PEER",
        ]
        XCTAssertEqual(try json(response.definition), expected)
    }

    func testLogNormalDelay() throws {
        let response = aResponse().withLogNormalRandomDelay(median: 90, sigma: 0.1)
        let expected: JSONValue = [
            "delayDistribution": ["type": "lognormal", "median": 90.0, "sigma": 0.1],
        ]
        XCTAssertEqual(try json(response.definition), expected)
    }

    func testMultiValueResponseHeader() throws {
        let response = aResponse().withHeader("Set-Cookie", ["a=1", "b=2"])
        let expected: JSONValue = [
            "headers": ["Set-Cookie": ["a=1", "b=2"]],
        ]
        XCTAssertEqual(try json(response.definition), expected)
    }

    func testScenarioFields() throws {
        let stub = get(urlEqualTo("/next"))
            .inScenario("flow")
            .whenScenarioStateIs("Started")
            .willSetStateTo("step-2")
            .willReturn(ok())
            .build()
        let decoded = try json(stub)
        XCTAssertEqual(decoded.objectValue?["scenarioName"], "flow")
        XCTAssertEqual(decoded.objectValue?["requiredScenarioState"], "Started")
        XCTAssertEqual(decoded.objectValue?["newScenarioState"], "step-2")
    }

    func testDateTimeMatcher() throws {
        let pattern = StringValuePattern.after("2020-01-01T00:00:00Z", expectedOffset: 3, expectedOffsetUnit: "days")
        let expected: JSONValue = [
            "after": "2020-01-01T00:00:00Z",
            "expectedOffset": 3,
            "expectedOffsetUnit": "days",
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testJsonSchemaMatcher() throws {
        let pattern = matchingJsonSchema(["type": "object"], version: .v202012)
        let expected: JSONValue = [
            "matchesJsonSchema": ["type": "object"],
            "schemaVersion": "V202012",
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testMultipartPattern() throws {
        let stub = post(urlEqualTo("/upload"))
            .withMultipartRequestBody(
                MultipartValuePattern(name: "file", matchingType: .any, bodyPatterns: [containing("data")])
            )
            .willReturn(ok())
            .build()
        let request = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue)
        let parts = try XCTUnwrap(request["multipartPatterns"]?.arrayValue)
        XCTAssertEqual(parts.first?.objectValue?["name"], "file")
        XCTAssertEqual(parts.first?.objectValue?["matchingType"], "ANY")
    }

    func testWebhookSerialisation() throws {
        let stub = post(urlEqualTo("/trigger"))
            .withWebhook(WebhookDefinition(
                method: "POST",
                url: "http://callback/hook",
                headers: ["Content-Type": "application/json"],
                body: "{}"
            ))
            .willReturn(ok())
            .build()
        let listeners = try XCTUnwrap(try json(stub).objectValue?["serveEventListeners"]?.arrayValue)
        let webhook = try XCTUnwrap(listeners.first?.objectValue)
        XCTAssertEqual(webhook["name"], "webhook")
        XCTAssertEqual(webhook["parameters"]?.objectValue?["url"], "http://callback/hook")
        XCTAssertEqual(webhook["parameters"]?.objectValue?["method"], "POST")
    }

    func testCustomHTTPMethodEncodes() throws {
        let stub = request("REPORT", urlEqualTo("/r")).willReturn(ok()).build()
        XCTAssertEqual(try json(stub).objectValue?["request"]?.objectValue?["method"], "REPORT")
    }

    func testHasExactlyEncodes() throws {
        let pattern = StringValuePattern.hasExactly([equalTo("1"), equalTo("2")])
        let expected: JSONValue = ["hasExactly": [["equalTo": "1"], ["equalTo": "2"]]]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testWebhookDelayEnumEncodes() throws {
        let webhook = WebhookDefinition(method: .post, url: "http://x", delay: .uniform(lower: 5, upper: 9))
            .asServeEventListener()
        let params = try XCTUnwrap(try json(webhook).objectValue?["parameters"]?.objectValue)
        XCTAssertEqual(params["delay"], ["type": "uniform", "lower": 5, "upper": 9])
    }

    /// String literal shorthand for a request matcher equals `.equalTo`.
    func testStringLiteralMatcher() throws {
        let stub = get(urlEqualTo("/x")).withHeader("Accept", "application/json").willReturn(ok()).build()
        let headers = try json(stub).objectValue?["request"]?.objectValue?["headers"]?.objectValue
        XCTAssertEqual(headers?["Accept"], ["equalTo": "application/json"])
    }

    func testStatusMessageAndBase64Encode() throws {
        let response = aResponse().withStatus(418).withStatusMessage("I'm a teapot").withBase64Body("aGk=")
        let expected: JSONValue = ["status": 418, "statusMessage": "I'm a teapot", "base64Body": "aGk="]
        XCTAssertEqual(try json(response.definition), expected)
    }

    /// An unknown delay-distribution type must round-trip losslessly, not throw.
    func testUnknownDelayDistributionPreserved() throws {
        let raw = #"{"fixedDelay":5,"delayDistribution":{"type":"exponential","mean":10}}"#
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(raw.utf8))
        let reencoded = try json(settings)
        XCTAssertEqual(reencoded.objectValue?["delayDistribution"]?.objectValue?["type"], "exponential")
        XCTAssertEqual(reencoded.objectValue?["delayDistribution"]?.objectValue?["mean"], 10)
    }

    func testAnythingAndRedirectEncode() throws {
        XCTAssertEqual(try json(StringValuePattern.anything), ["anything": "(always)"])
        let redirect = temporaryRedirect(to: "/new")
        XCTAssertEqual(try json(redirect.definition), ["status": 302, "headers": ["Location": "/new"]])
        XCTAssertEqual(try json(jsonResponse(["ok": true], status: 201).definition),
                       ["status": 201, "headers": ["Content-Type": "application/json"], "jsonBody": ["ok": true]])
    }

    func testRedirectAndStatusFactoriesEncode() throws {
        XCTAssertEqual(try json(status(418).definition), ["status": 418])
        XCTAssertEqual(try json(permanentRedirect(to: "/p").definition),
                       ["status": 301, "headers": ["Location": "/p"]])
        XCTAssertEqual(try json(seeOther(to: "/s").definition),
                       ["status": 303, "headers": ["Location": "/s"]])
    }

    func testRecordSpecFiltersMethodEncodes() throws {
        let spec = RecordSpec(targetBaseUrl: "http://up",
                              filters: RecordFilters(urlPathPattern: "/api/.*", method: .get))
        let filters = try XCTUnwrap(try json(spec).objectValue?["filters"]?.objectValue)
        XCTAssertEqual(filters["method"], "GET")   // HTTPMethod encodes as a bare string
        XCTAssertEqual(filters["urlPathPattern"], "/api/.*")
    }

    func testClientIpAndGzipDisabledEncode() throws {
        let stub = get(urlEqualTo("/ip"))
            .withClientIp(equalTo("1.2.3.4"))
            .willReturn(ok().withGzipDisabled())
            .build()
        let encoded = try json(stub)
        XCTAssertEqual(encoded.objectValue?["request"]?.objectValue?["clientIp"], ["equalTo": "1.2.3.4"])
        XCTAssertEqual(encoded.objectValue?["response"]?.objectValue?["headers"]?.objectValue?["Content-Encoding"], "none")
    }

    func testXmlNamespaceAwarenessEncode() throws {
        let pattern = StringValuePattern.equalToXml("<a/>", namespaceAwareness: .off)
        XCTAssertEqual(try json(pattern), ["equalToXml": "<a/>", "namespaceAwareness": "NONE"])
    }

    func testAdminAuthorizationHeaderValues() {
        XCTAssertEqual(
            AdminAuthorization.basic(username: "admin", password: "s3cret").headerValue,
            "Basic " + Data("admin:s3cret".utf8).base64EncodedString()
        )
        XCTAssertEqual(AdminAuthorization.bearer(token: "tok").headerValue, "Bearer tok")
        XCTAssertEqual(AdminAuthorization.header(value: "Custom xyz").headerValue, "Custom xyz")
    }

    /// A nil optional must be omitted entirely, not encoded as JSON null.
    func testUnsetFieldsAreOmitted() throws {
        let stub = get(urlEqualTo("/x")).willReturn(ok()).build()
        let request = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue)
        XCTAssertNil(request["urlPattern"])
        XCTAssertNil(request["headers"])
        XCTAssertNil(request["bodyPatterns"])
    }

    // MARK: - String matchers

    func testBinaryEqualToEncodes() throws {
        XCTAssertEqual(try json(binaryEqualTo("aGVsbG8=")), ["binaryEqualTo": "aGVsbG8="])
    }

    func testEqualToIgnoreCaseEncodes() throws {
        XCTAssertEqual(try json(equalToIgnoreCase("Text/Plain")),
                       ["equalTo": "Text/Plain", "caseInsensitive": true])
        // The `caseInsensitive:` variant of `equalTo` must produce the same shape.
        XCTAssertEqual(try json(equalTo("Text/Plain", caseInsensitive: true)),
                       ["equalTo": "Text/Plain", "caseInsensitive": true])
        // Default (case-sensitive) must NOT emit the flag at all.
        XCTAssertNil(try json(equalTo("Text/Plain")).objectValue?["caseInsensitive"])
    }

    func testNotMatchingAndNotContainingEncode() throws {
        XCTAssertEqual(try json(notMatching("[0-9]+")), ["doesNotMatch": "[0-9]+"])
        XCTAssertEqual(try json(notContaining("bad")), ["doesNotContain": "bad"])
    }

    func testAbsentEncodes() throws {
        XCTAssertEqual(try json(absent), ["absent": true])
        // `withoutHeader` is sugar for an `absent` header matcher.
        let stub = get(urlEqualTo("/x")).withoutHeader("X-Trace").willReturn(ok()).build()
        let headers = try json(stub).objectValue?["request"]?.objectValue?["headers"]?.objectValue
        XCTAssertEqual(headers?["X-Trace"], ["absent": true])
    }

    func testEqualToJsonRawParsesOperand() throws {
        // The `raw:` variant must parse the string into structured JSON, not
        // embed it as a quoted string.
        XCTAssertEqual(try json(equalToJson(raw: #"{"a":[1,2]}"#)), ["equalToJson": ["a": [1, 2]]])
    }

    func testOrAndNotCombinatorsEncode() throws {
        XCTAssertEqual(try json(or(equalTo("a"), equalTo("b"))),
                       ["or": [["equalTo": "a"], ["equalTo": "b"]]])
        XCTAssertEqual(try json(not(equalTo("x"))), ["not": ["equalTo": "x"]])
    }

    func testMatchingJsonPathSubmatcherEncodes() throws {
        let pattern = matchingJsonPath("$.name", containing("bob"))
        XCTAssertEqual(try json(pattern),
                       ["matchesJsonPath": ["expression": "$.name", "contains": "bob"]])
    }

    func testIncludesEncodes() throws {
        let pattern = StringValuePattern.includes([containing("red"), equalTo("blue")])
        XCTAssertEqual(try json(pattern),
                       ["includes": [["contains": "red"], ["equalTo": "blue"]]])
    }

    // MARK: - XML

    func testEqualToXmlPlaceholdersEncode() throws {
        let pattern = StringValuePattern.equalToXml(
            "<a>${x}</a>",
            enablePlaceholders: true,
            placeholderOpeningDelimiterRegex: "\\$\\{",
            placeholderClosingDelimiterRegex: "\\}",
            exemptedComparisons: ["NAMESPACE_URI"],
            ignoreOrderOfSameNode: true
        )
        let expected: JSONValue = [
            "equalToXml": "<a>${x}</a>",
            "enablePlaceholders": true,
            "placeholderOpeningDelimiterRegex": "\\$\\{",
            "placeholderClosingDelimiterRegex": "\\}",
            "exemptedComparisons": ["NAMESPACE_URI"],
            "ignoreOrderOfSameNode": true,
        ]
        XCTAssertEqual(try json(pattern), expected)
        // Plain equalToXml stays minimal.
        XCTAssertEqual(try json(equalToXml("<a/>")), ["equalToXml": "<a/>"])
    }

    func testMatchingXPathNamespacesEncode() throws {
        let pattern = matchingXPath("/t:note/t:to", namespaces: ["t": "urn:test"])
        XCTAssertEqual(try json(pattern),
                       ["matchesXPath": "/t:note/t:to", "xPathNamespaces": ["t": "urn:test"]])
        // No namespaces -> no xPathNamespaces key.
        XCTAssertNil(try json(matchingXPath("/a")).objectValue?["xPathNamespaces"])
    }

    func testMatchingXPathSubmatcherEncodes() throws {
        let pattern = StringValuePattern.matchingXPath("/note/to", containing("Bob"), namespaces: ["t": "urn:t"])
        let expected: JSONValue = [
            "matchesXPath": ["expression": "/note/to", "contains": "Bob"],
            "xPathNamespaces": ["t": "urn:t"],
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    // MARK: - Date/time

    func testDateTimeTruncateAndOffsetFieldsEncode() throws {
        let pattern = StringValuePattern.before(
            "2030-01-01T00:00:00Z",
            actualFormat: "yyyy-MM-dd",
            truncateExpected: "first day of month",
            truncateActual: "first day of month",
            expectedOffset: 3,
            expectedOffsetUnit: "days",
            applyTruncationLast: true
        )
        let expected: JSONValue = [
            "before": "2030-01-01T00:00:00Z",
            "actualFormat": "yyyy-MM-dd",
            "truncateExpected": "first day of month",
            "truncateActual": "first day of month",
            "expectedOffset": 3,
            "expectedOffsetUnit": "days",
            "applyTruncationLast": true,
        ]
        XCTAssertEqual(try json(pattern), expected)
    }

    func testEqualToDateTimeEncodes() throws {
        XCTAssertEqual(try json(equalToDateTime("2030-01-01T00:00:00Z")),
                       ["equalToDateTime": "2030-01-01T00:00:00Z"])
    }

    // MARK: - JSON schema

    func testMatchingJsonSchemaNoVersionAndRaw() throws {
        // Without a version, no schemaVersion key is emitted.
        XCTAssertEqual(try json(matchingJsonSchema(["type": "string"])),
                       ["matchesJsonSchema": ["type": "string"]])
        // The raw: variant parses the schema string into structured JSON.
        XCTAssertEqual(try json(StringValuePattern.matchingJsonSchema(raw: #"{"type":"number"}"#, version: .v7)),
                       ["matchesJsonSchema": ["type": "number"], "schemaVersion": "V7"])
    }

    // MARK: - Request-side fields

    func testUrlPathTemplateAndPathParamsEncode() throws {
        let stub = get(urlPathTemplate("/things/{id}"))
            .withPathParam("id", equalTo("5"))
            .willReturn(ok()).build()
        let request = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue)
        XCTAssertEqual(request["urlPathTemplate"], "/things/{id}")
        XCTAssertEqual(request["pathParameters"]?.objectValue?["id"], ["equalTo": "5"])
    }

    func testFormParametersEncode() throws {
        let stub = post(urlPathEqualTo("/form"))
            .withFormParam("name", equalTo("bob"))
            .willReturn(ok()).build()
        let request = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue)
        XCTAssertEqual(request["formParameters"]?.objectValue?["name"], ["equalTo": "bob"])
    }

    func testHostPortSchemeEncode() throws {
        let stub = get(urlPathEqualTo("/hp"))
            .withHost(equalTo("example.com"))
            .withPort(8080)
            .withScheme("https")
            .willReturn(ok()).build()
        let request = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue)
        XCTAssertEqual(request["host"], ["equalTo": "example.com"])
        XCTAssertEqual(request["port"], 8080)
        XCTAssertEqual(request["scheme"], "https")
    }

    func testMultipartAllWithHeadersEncodes() throws {
        let stub = post(urlEqualTo("/upload"))
            .withMultipartRequestBody(
                MultipartValuePattern(
                    name: "file",
                    matchingType: .all,
                    headers: ["Content-Type": containing("text")],
                    bodyPatterns: [containing("a"), containing("b")]
                )
            )
            .willReturn(ok()).build()
        let parts = try XCTUnwrap(try json(stub).objectValue?["request"]?.objectValue?["multipartPatterns"]?.arrayValue)
        let part = try XCTUnwrap(parts.first?.objectValue)
        XCTAssertEqual(part["matchingType"], "ALL")
        XCTAssertEqual(part["headers"]?.objectValue?["Content-Type"], ["contains": "text"])
        XCTAssertEqual(part["bodyPatterns"]?.arrayValue?.count, 2)
    }

    // MARK: - Response options

    func testUniformRandomDelayEncodes() throws {
        let response = aResponse().withUniformRandomDelay(lower: 50, upper: 60)
        XCTAssertEqual(try json(response.definition),
                       ["delayDistribution": ["type": "uniform", "lower": 50, "upper": 60]])
    }

    func testChunkedDribbleDelayEncodes() throws {
        let response = aResponse().withChunkedDribbleDelay(numberOfChunks: 3, totalDuration: 150)
        XCTAssertEqual(try json(response.definition),
                       ["chunkedDribbleDelay": ["numberOfChunks": 3, "totalDuration": 150]])
    }

    func testTransformerParameterEncodes() throws {
        let response = aResponse().withStatus(200)
            .withTransformers("response-template")
            .withTransformerParameter("greeting", "hi")
            .withTransformerParameter("count", 3)
        let decoded = try json(response.definition)
        XCTAssertEqual(decoded.objectValue?["transformers"], ["response-template"])
        XCTAssertEqual(decoded.objectValue?["transformerParameters"], ["greeting": "hi", "count": 3])
    }

    func testBodyFileEncodes() throws {
        let response = aResponse().withStatus(200).withBodyFile("greeting.json")
        XCTAssertEqual(try json(response.definition), ["status": 200, "bodyFileName": "greeting.json"])
    }

    func testJsonBodyEncodes() throws {
        // withJsonBody alone emits jsonBody (no Content-Type unless set).
        let response = aResponse().withStatus(200).withJsonBody(["id": 1])
        XCTAssertEqual(try json(response.definition), ["status": 200, "jsonBody": ["id": 1]])
        // okForJson also stamps a Content-Type header.
        let helper = try json(okForJson(["id": 1]).definition)
        XCTAssertEqual(helper.objectValue?["headers"]?.objectValue?["Content-Type"], "application/json")
        XCTAssertEqual(helper.objectValue?["jsonBody"], ["id": 1])
    }

    func testMultiValueResponseHeaderPreservesOrder() throws {
        let response = aResponse().withHeader("Set-Cookie", ["a=1", "b=2"])
        XCTAssertEqual(try json(response.definition).objectValue?["headers"]?.objectValue?["Set-Cookie"],
                       ["a=1", "b=2"])
    }

    // MARK: - Webhook

    func testWebhookRequestPhasesAndJsonBodyEncode() throws {
        let listener = ServeEventListenerDefinition(
            name: "webhook",
            parameters: ["url": "http://cb"],
            requestPhases: ["AFTER_COMPLETE"]
        )
        let decoded = try json(listener)
        XCTAssertEqual(decoded.objectValue?["requestPhases"], ["AFTER_COMPLETE"])

        let webhook = WebhookDefinition(
            method: .post, url: "http://cb",
            headers: ["Content-Type": "application/json"],
            jsonBody: ["ok": true],
            delay: .fixed(milliseconds: 100)
        ).asServeEventListener()
        let params = try XCTUnwrap(try json(webhook).objectValue?["parameters"]?.objectValue)
        // WireMock's webhook has no `jsonBody` param (it's ignored), so it is
        // serialized into `body` as a JSON string; no `jsonBody` key is emitted.
        XCTAssertNil(params["jsonBody"])
        XCTAssertEqual(params["body"], #"{"ok":true}"#)
        XCTAssertEqual(params["headers"], ["Content-Type": "application/json"])
        XCTAssertEqual(params["delay"], ["type": "fixed", "milliseconds": 100])
    }

    // MARK: - Global settings round-trip

    func testGlobalSettingsRoundTripWithDelayDistribution() throws {
        let settings = GlobalSettings(
            fixedDelay: 10,
            delayDistribution: .lognormal(median: 90, sigma: 0.1),
            proxyPassThrough: false,
            extended: ["custom": ["nested": 1]]
        )
        let decoded = try json(settings)
        XCTAssertEqual(decoded.objectValue?["fixedDelay"], 10)
        XCTAssertEqual(decoded.objectValue?["delayDistribution"],
                       ["type": "lognormal", "median": 90.0, "sigma": 0.1])
        XCTAssertEqual(decoded.objectValue?["proxyPassThrough"], false)
        // `extended` nests under the server's `extended` key (not top-level),
        // matching Java — a top-level key would be silently ignored.
        XCTAssertEqual(decoded.objectValue?["extended"], ["custom": ["nested": 1]])
    }

    // MARK: - Acceptance coverage: verbs, URL forms, status helpers, new DSL

    func testAllStubVerbsEncodeMethod() throws {
        let cases: [(MappingBuilder, String)] = [
            (get(urlEqualTo("/x")), "GET"), (post(urlEqualTo("/x")), "POST"),
            (put(urlEqualTo("/x")), "PUT"), (patch(urlEqualTo("/x")), "PATCH"),
            (delete(urlEqualTo("/x")), "DELETE"), (head(urlEqualTo("/x")), "HEAD"),
            (options(urlEqualTo("/x")), "OPTIONS"), (trace(urlEqualTo("/x")), "TRACE"),
            (any(urlEqualTo("/x")), "ANY"), (request(.getOrHead, urlEqualTo("/x")), "GET_OR_HEAD"),
        ]
        for (builder, method) in cases {
            XCTAssertEqual(try json(builder.willReturn(ok()).build()).objectValue?["request"]?.objectValue?["method"],
                           .string(method), "verb \(method)")
        }
    }

    func testUrlFormsEncodeCorrectKey() throws {
        func req(_ b: MappingBuilder) throws -> [String: JSONValue]? {
            try json(b.willReturn(ok()).build()).objectValue?["request"]?.objectValue
        }
        XCTAssertEqual(try req(get(urlEqualTo("/a")))?["url"], "/a")
        XCTAssertEqual(try req(get(urlMatching("/a.*")))?["urlPattern"], "/a.*")
        XCTAssertEqual(try req(get(urlPathEqualTo("/a")))?["urlPath"], "/a")
        XCTAssertEqual(try req(get(urlPathMatching("/a.*")))?["urlPathPattern"], "/a.*")
        XCTAssertEqual(try req(get(urlPathTemplate("/a/{id}")))?["urlPathTemplate"], "/a/{id}")
    }

    func testVerificationVerbsEncodeMethod() throws {
        let cases: [(RequestPatternBuilder, String)] = [
            (getRequestedFor(urlEqualTo("/x")), "GET"), (postRequestedFor(urlEqualTo("/x")), "POST"),
            (putRequestedFor(urlEqualTo("/x")), "PUT"), (patchRequestedFor(urlEqualTo("/x")), "PATCH"),
            (deleteRequestedFor(urlEqualTo("/x")), "DELETE"), (headRequestedFor(urlEqualTo("/x")), "HEAD"),
            (optionsRequestedFor(urlEqualTo("/x")), "OPTIONS"), (anyRequestedFor(urlEqualTo("/x")), "ANY"),
            (traceRequestedFor(urlEqualTo("/x")), "TRACE"),
            (requestedFor(.put, urlEqualTo("/x")), "PUT"),
        ]
        for (builder, method) in cases {
            XCTAssertEqual(try json(builder.pattern).objectValue?["method"], .string(method), "verb \(method)")
        }
    }

    // NOTE: temporarily split to isolate a CI-only (macOS 14 / Swift 6.0) signal-5
    // crash that reproduces on neither macOS 26/Swift 6.3 nor TSan/ASan locally.
    func testBinaryEqualToDataOverloadRawEncode() throws {
        // Data overload (Java's binaryEqualTo(byte[])), encoded directly — no json() helper.
        let raw = String(decoding: try JSONEncoder().encode(binaryEqualTo(Data("hello".utf8))), as: UTF8.self)
        XCTAssertEqual(raw, #"{"binaryEqualTo":"aGVsbG8="}"#)
    }

    func testBinaryEqualToStringOverloadRawEncode() throws {
        let raw = String(decoding: try JSONEncoder().encode(binaryEqualTo("aGVsbG8=")), as: UTF8.self)
        XCTAssertEqual(raw, #"{"binaryEqualTo":"aGVsbG8="}"#)
    }

    func testBinaryEqualToDataViaJsonHelper() throws {
        XCTAssertEqual(try json(binaryEqualTo(Data("hello".utf8))), ["binaryEqualTo": "aGVsbG8="])
    }

    func testProxyResponseBuilderEncodesProxyFields() throws {
        // proxiedFrom returns the proxy builder; its Java-named tweaks land on the
        // right JSON fields, and multi-value additional headers use the array form.
        let response = aResponse()
            .proxiedFrom("http://backend")
            .withAdditionalRequestHeader("X-One", "a")
            .withAdditionalRequestHeader("X-Multi", ["a", "b"])
            .withRemoveRequestHeader("X-Drop")
            .withProxyUrlPrefixToRemove("/prefix")
        let stub = get(urlEqualTo("/p")).willReturn(response).build()
        let resp = try XCTUnwrap(try json(stub).objectValue?["response"]?.objectValue)
        XCTAssertEqual(resp["proxyBaseUrl"], "http://backend")
        XCTAssertEqual(resp["additionalProxyRequestHeaders"], ["X-One": "a", "X-Multi": ["a", "b"]])
        XCTAssertEqual(resp["removeProxyRequestHeaders"], ["X-Drop"])
        XCTAssertEqual(resp["proxyUrlPrefixToRemove"], "/prefix")
    }

    func testProxyBuilderCarriesForwardBaseResponseConfig() throws {
        // Base config set before proxiedFrom must survive onto the proxy builder.
        let response = aResponse().withHeader("X-Base", "kept").proxiedFrom("http://b")
        let resp = try XCTUnwrap(try json(get(urlEqualTo("/p")).willReturn(response).build()).objectValue?["response"]?.objectValue)
        XCTAssertEqual(resp["proxyBaseUrl"], "http://b")
        XCTAssertEqual(resp["headers"]?.objectValue?["X-Base"], "kept")
    }

    func testResponseStatusHelpersEncode() throws {
        let cases: [(ResponseDefinitionBuilder, Int)] = [
            (created(), 201), (noContent(), 204), (badRequest(), 400), (badRequestEntity(), 422),
            (unauthorized(), 401), (forbidden(), 403), (notFound(), 404),
            (serverError(), 500), (serviceUnavailable(), 503),
        ]
        for (builder, status) in cases {
            XCTAssertEqual(try json(builder.definition).objectValue?["status"], .int(status), "status \(status)")
        }
        let empty = try json(okForEmptyJson().definition).objectValue
        XCTAssertEqual(empty?["status"], 200)
        XCTAssertEqual(empty?["jsonBody"], .object([:]))
        let typed = try json(okForContentType("text/csv", "a,b").definition).objectValue
        XCTAssertEqual(typed?["status"], 200)
        XCTAssertEqual(typed?["body"], "a,b")
        XCTAssertEqual(typed?["headers"]?.objectValue?["Content-Type"], "text/csv")
    }

    func testMappingMetadataEncode() throws {
        let id = UUID()
        let mapping = try json(get(urlEqualTo("/x")).withId(id).withName("my-stub").persistent().willReturn(ok()).build()).objectValue
        XCTAssertEqual(mapping?["id"], .string(id.uuidString))
        XCTAssertEqual(mapping?["name"], "my-stub")
        XCTAssertEqual(mapping?["persistent"], true)
    }

    func testWithoutParamsEncodeAbsent() throws {
        let req = try json(get(urlEqualTo("/x")).withoutQueryParam("q").withoutFormParam("f").willReturn(ok()).build())
            .objectValue?["request"]?.objectValue
        XCTAssertEqual(req?["queryParameters"]?.objectValue?["q"], ["absent": true])
        XCTAssertEqual(req?["formParameters"]?.objectValue?["f"], ["absent": true])
    }

    func testAndMatchingEncodesCustomMatcher() throws {
        let req = try json(get(urlEqualTo("/x")).andMatching("path-matcher", parameters: ["k": 1]).willReturn(ok()).build())
            .objectValue?["request"]?.objectValue
        XCTAssertEqual(req?["customMatcher"], ["name": "path-matcher", "parameters": ["k": 1]])
    }

    func testWithPostServeActionEncodes() throws {
        let mapping = try json(get(urlEqualTo("/x")).withPostServeAction("webhook", parameters: ["url": "http://cb"]).willReturn(ok()).build()).objectValue
        let action = mapping?["postServeActions"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(action?["name"], "webhook")
        XCTAssertEqual(action?["parameters"], ["url": "http://cb"])
    }

    func testDateTimeNowAndXPathAndMultiValueFreeFunctions() throws {
        XCTAssertEqual(try json(beforeNow()), ["before": "now"])
        XCTAssertEqual(try json(afterNow()), ["after": "now"])
        XCTAssertEqual(try json(isNow()), ["equalToDateTime": "now"])
        XCTAssertEqual(try json(matchingXPath("/a", equalTo("x"))), ["matchesXPath": ["expression": "/a", "equalTo": "x"]])
        XCTAssertEqual(try json(hasExactly(equalTo("1"), equalTo("2"))), ["hasExactly": [["equalTo": "1"], ["equalTo": "2"]]])
        XCTAssertEqual(try json(includes(equalTo("1"))), ["includes": [["equalTo": "1"]]])
    }

    func testLognormalMaxValueMultipartFileNameRecordFiltersEncode() throws {
        XCTAssertEqual(try json(aResponse().withLogNormalRandomDelay(median: 90, sigma: 0.1, maxValue: 60).definition).objectValue?["delayDistribution"],
                       ["type": "lognormal", "median": 90.0, "sigma": 0.1, "maxValue": 60.0])
        let part = MultipartValuePattern(name: "file", fileName: "a.txt", bodyPatterns: [.containing("x")])
        XCTAssertEqual(try json(part).objectValue?["fileName"], "a.txt")
        let filters = RecordFilters(url: "/a", ids: ["id1"], allowNonProxied: true)
        let encoded = try json(filters).objectValue
        XCTAssertEqual(encoded?["url"], "/a")
        XCTAssertEqual(encoded?["ids"], ["id1"])
        XCTAssertEqual(encoded?["allowNonProxied"], true)
    }
}
