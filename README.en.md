# WireMockSwift

A native Swift client and DSL for [WireMock](https://wiremock.org) that closely mirrors the Java DSL
and Admin API.

This is **not** a re-implementation of the server — the library drives a real WireMock server (launched
via Docker or the standalone jar) through its `/__admin/**` REST API. All request matching, response
templating and JSON comparison are performed by the battle-tested Java engine, so behaviour is identical
to Java WireMock; this package gives you an expressive, type-safe way to configure and verify it from
Swift.

- ✅ Full set of request matchers, all response options, faults and delays, scenarios, proxying,
  record/playback, verification, near-misses, settings, files, metadata and webhooks
- ✅ Covers the entire documented `/__admin` Admin API surface
- ✅ Synchronous API (like Java WireMock) + `callAsync` for `async` contexts; `Sendable` under Swift 6
  strict concurrency; macOS + Linux + iOS
- ✅ Golden-JSON + live-server test suites; a raw-JSON escape hatch for anything not yet modelled

> **Status:** early development (0.x), first release — `0.1.0`. The API may still change.
> License — Apache-2.0. Verified against WireMock **3.13.2**.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Running a WireMock server](#running-a-wiremock-server)
- [Creating stubs](#creating-stubs)
- [Request matchers](#request-matchers)
- [Responses](#responses)
- [Verification](#verification)
- [Scenarios](#scenarios-state-management)
- [Proxying, faults and delays](#proxying-faults-and-delays)
- [Recording, files, metadata and settings](#recording-files-metadata-and-settings)
- [Webhooks](#webhooks)
- [Escape hatch](#escape-hatch)
- [Errors and concurrency](#errors-and-concurrency)
- [Usage in tests](#usage-in-tests)
- [Continuous integration](#continuous-integration)
- [Platform notes](#platform-notes)
- [Parity with Java WireMock](#parity-with-java-wiremock)
- [Testing this package](#testing-this-package)
- [License](#license)

## Requirements

- Swift 6.0+ (builds clean under `-strict-concurrency=complete`)
- A running WireMock **3.x** server (Docker image or standalone jar)
- Platforms: macOS 12+, iOS 15+, tvOS 15+, watchOS 8+ and Linux.

## Installation

Swift Package Manager — add to `Package.swift`:

```swift
.package(url: "https://github.com/ekolomyychenko/WireMockSwift.git", from: "0.1.0")
```

and add the product to your (test) target:

```swift
.testTarget(name: "MyAppTests", dependencies: [.product(name: "WireMock", package: "WireMockSwift")])
```

## Quick start

Start a server — the standalone jar needs only a JDK and runs anywhere (see
[below](#running-a-wiremock-server) for all options, including restricted/corporate machines):

```bash
java -jar wiremock-standalone-3.13.2.jar --port 8080
```

Stub a response, call it, and verify it was called:

```swift
import WireMock

let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)

try wireMock.stubFor(
    get(urlEqualTo("/hello"))
        .willReturn(okForJson(["message": "world"]))
)

// ... your code under test hits http://localhost:8080/hello ...

try wireMock.verify(getRequestedFor(urlEqualTo("/hello")))

try wireMock.resetAll()   // clean state between tests
```

## Running a WireMock server

There are two options; choose by your environment and where the tests run.

**1. Standalone jar (recommended, most portable)** — needs only a JDK, no Docker, no install step.
Download it once from Maven Central and preferably **commit it into your repository** so builds are
reproducible offline:

```bash
curl -sL -o wiremock.jar \
  https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/3.13.2/wiremock-standalone-3.13.2.jar
java -jar wiremock.jar --port 8080
```

**2. Docker** — convenient for Linux CI, but **often blocked on locked-down corporate machines** — so
don't make it your only path:

```bash
docker run --rm -p 8080:8080 wiremock/wiremock:3.13.2
```

> **Restricted / corporate environments.** Prefer the **jar** — it needs only a JDK (often already
> present for Android/JVM tooling), and it can be committed into the repo, so neither Docker nor the
> network is required. If your machine allows neither Docker nor a JDK, run WireMock once on a
> shared/CI host and point all clients at it over the network via `WireMock(baseURL:)` — the server
> doesn't have to be local.

> **The port is not fixed.** The `8080` in the examples is just a default. Run WireMock on any port
> (`--port <N>`) and target the client via `WireMock(port:)` / `WireMock(baseURL:)` or the `WIREMOCK_URL`
> variable. Nothing is tied to 8080 — you can bring up several instances on different ports (e.g. for
> parallel suites).

## Creating stubs

Stubs are built with an expressive value-typed DSL that mirrors WireMock's Java `MappingBuilder`:

```swift
try wireMock.stubFor(
    post(urlPathEqualTo("/things"))
        .withHeader("Content-Type", equalTo("application/json"))
        .withQueryParam("verbose", equalTo("true"))
        .withRequestBody(matchingJsonPath("$.name"))
        .atPriority(1)
        .withMetadata(["team": "payments"])
        .willReturn(okForJson(["id": 1]))
)
```

There is an entry point for every method — `get`, `post`, `put`, `patch`, `delete`, `head`, `options`,
`trace`, `any`, and `request(_:_:)` for everything else: `request(.patch, urlEqualTo("/x"))`, or, since
`HTTPMethod` is `ExpressibleByStringLiteral`, an arbitrary verb as a string — `request("REPORT", urlEqualTo("/x"))`.
URLs are matched via `urlEqualTo`, `urlMatching` (regex), `urlPathEqualTo`, `urlPathMatching`,
`urlPathTemplate` or `anyUrl`.

Request criteria: `withHeader` / `withoutHeader`, `withQueryParam`, `withCookie`, `withPathParam`,
`withFormParam`, `withRequestBody`, `withMultipartRequestBody`, `withBasicAuth(username:password:)`,
`withHost` / `withPort` / `withScheme`.

## Request matchers

Every matcher is available both as a `StringValuePattern` factory (`.equalTo(…)`) and as a free
function (`equalTo(…)`), mirroring the Java DSL:

```swift
equalTo("text")                      // + caseInsensitive: / equalToIgnoreCase(_:)
containing("part")                   // notContaining(_:)
matching("[0-9]+")                   // notMatching(_:) (regex)
absent                               // header/param must be absent
anything                             // matches any value
binaryEqualTo("aGk=")                // byte-for-byte base64 comparison

equalToJson(["a": 1], ignoreArrayOrder: true, ignoreExtraElements: true)
matchingJsonPath("$.name")
matchingJsonPath("$.name", containing("bob"))   // with a sub-matcher
matchingJsonSchema(["type": "object"], version: .v202012)

equalToXml("<a/>")
StringValuePattern.equalToXml("<a/>", enablePlaceholders: true)   // options → factory form
matchingXPath("/note/to[text()='Bob']", namespaces: ["ns": "http://x"])

before("2020-01-01T00:00:00Z")                   // after(_:), equalToDateTime(_:)
StringValuePattern.after("2020-01-01T00:00:00Z", expectedOffset: 3, expectedOffsetUnit: "days")  // options → factory

and(containing("a"), notContaining("b"))         // or(...), not(...)
hasExactly(equalTo("1"), equalTo("2"))           // repeated multi-valued params
includes(containing("red"))
```

A bare string literal is shorthand for `.equalTo`, so `withHeader("Accept", "application/json")` and
`withHeader("Accept", equalTo("application/json"))` are equivalent.

> Free functions carry the **common** parameters; **advanced options** (XML placeholders,
> datetime offset/truncation, XPath sub-matchers) live only on the static `StringValuePattern.`
> factories.

> **Numeric matchers** (`equalToNumber`/`greaterThan`/`lessThan`/…) are a **WireMock 4.0+** feature;
> the 3.13.2 server rejects them with HTTP 422, so they are not part of this DSL. On 3.x, match numbers
> with a JSONPath predicate: `matchingJsonPath("$[?(@.age > 5)]")`.

## Responses

```swift
ok()                                  // 200
ok("plain body")
okForJson(["id": 1])                  // 200 + application/json
okForContentType("text/csv", "a,b,c") // 200 + given Content-Type
jsonResponse(["error": "nope"], status: 422)
created(); noContent(); badRequest(); notFound(); serverError()   // and more
temporaryRedirect(to: "/new"); permanentRedirect(to: "/new"); seeOther(to: "/other")
status(418)

aResponse()
    .withStatus(200)
    .withStatusMessage("OK")
    .withHeader("X-Trace", "abc")          // multi-valued: .withHeader("Set-Cookie", ["a=1", "b=2"])
    .withJsonBody(["ok": true])            // or withBody / withBase64Body / withBodyFile
    .withTransformers("response-template") // server-side Handlebars templating
    .withTransformerParameter("name", "Bob")
```

## Verification

```swift
// At least once:
try wireMock.verify(postRequestedFor(urlEqualTo("/things")))

// Exact / relative counts — throws VerificationError if not satisfied:
try wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
try wireMock.verify(.moreThanOrExactly(1), getRequestedFor(urlEqualTo("/ping")))
try wireMock.verify(.lessThan(5), getRequestedFor(urlEqualTo("/ping")))

// Journal queries:
let count   = try wireMock.count(getRequestedFor(urlEqualTo("/ping")))
let matched = try wireMock.findAll(postRequestedFor(urlEqualTo("/things")))
let events  = try wireMock.getAllServeEvents()
let unmatched = try wireMock.getUnmatchedRequests()
let nearMisses = try wireMock.findNearMissesForAllUnmatched()

try wireMock.resetRequests()                                   // clear the journal
try wireMock.removeServeEvents(matching: getRequestedFor(urlEqualTo("/ping")))
```

`RequestPatternBuilder` supports the same criteria as stub creation (`withHeader`, `withoutHeader`,
`withQueryParam`, `withCookie`, `withRequestBody`, `withBasicAuth`, etc.).

## Scenarios (state management)

```swift
try wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("Started").willSetStateTo("step-2")
        .willReturn(ok("first"))
)
try wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("step-2").willReturn(ok("second"))
)

let scenarios = try wireMock.getAllScenarios()
try wireMock.setScenarioState(name: "flow", state: "step-2")
try wireMock.resetScenario(name: "flow")     // one scenario
try wireMock.resetAllScenarios()             // all
```

## Proxying, faults and delays

```swift
// Proxy unmatched/selected traffic to a real backend:
try wireMock.stubFor(
    any(urlPathMatching("/api/.*")).willReturn(
        aResponse().proxiedFrom("https://api.example.com")
            .withProxyUrlPrefixToRemove("/api")
            .withAdditionalRequestHeader("X-From", "wiremock")
    )
)

// Faults:
aResponse().withFault(.connectionResetByPeer)   // .emptyResponse, .malformedResponseChunk, .randomDataThenClose

// Delays:
aResponse().withFixedDelay(500)
aResponse().withLogNormalRandomDelay(median: 90, sigma: 0.1)
aResponse().withUniformRandomDelay(lower: 15, upper: 25)
aResponse().withChunkedDribbleDelay(numberOfChunks: 5, totalDuration: 1000)

// Globally (applied to every response):
try wireMock.setGlobalFixedDelay(200)
```

## Recording, files, metadata and settings

```swift
try wireMock.startRecording(targetBaseUrl: "https://api.example.com")
// ... drive traffic through the proxy ...
let generated = try wireMock.stopRecording()   // [StubMapping]
let status = try wireMock.getRecordingStatus()
let snapshot = try wireMock.takeSnapshot()
// ⚠️ `targetBaseUrl` must point at a SEPARATE upstream — pointing it back at the same
//    WireMock instance creates a self-proxying loop that hangs.

// __files:
try wireMock.putFile(named: "body.json", text: #"{"hi":true}"#, contentType: "application/json")
let names = try wireMock.listFiles()
let data = try wireMock.getFile(named: "body.json")
try wireMock.deleteFile(named: "body.json")
// Note: WireMock 3.x does not percent-decode path segments, so scenario names and __files
// names must be URL-safe — a name with spaces/`%`/unicode is stored and addressed in its
// encoded form (e.g. "a b.json" → "a%20b.json").

// Metadata and bulk import:
let stubs = try wireMock.findStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try wireMock.removeStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try wireMock.importMappings([stub1, stub2])

// Settings:
try wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 100))
let settings = try wireMock.getGlobalSettings()   // extended settings live in .extended (nested `extended` key)
let health = try wireMock.getHealth()
```

## Webhooks

Trigger an outbound HTTP call when a stub fires (the built-in `webhook` listener):

```swift
try wireMock.stubFor(
    post(urlEqualTo("/order")).willReturn(ok()).withWebhook(
        WebhookDefinition(
            method: .post,
            url: "https://callback.example.com/hook",
            headers: ["Content-Type": "application/json"],
            body: #"{"event":"order.created"}"#,
            delay: .fixed(milliseconds: 200)
        )
    )
)
```

## Escape hatch

Anything not yet modelled by the typed DSL (extension matchers, future server capabilities) can still be
registered from raw JSON, so you're never blocked:

```swift
try wireMock.register(raw: #"""
{ "request": { "method": "GET", "url": "/raw" },
  "response": { "status": 200, "body": "ok" } }
"""#)

try wireMock.register(json: ["request": ["method": "GET", "url": "/x"],
                                   "response": ["status": 204]])
```

`StringValuePattern([...])` similarly builds an arbitrary matcher from raw fields.

## Errors and concurrency

Every call throws a typed **`WireMockError`** (all `CustomStringConvertible`):

- `.unexpectedStatus(code:body:)` — the server rejected the request (e.g. HTTP 422 for a 4.x-only matcher
  on a 3.x server); the response body is attached.
- `.transport(underlying:)` — connection refused, timeout, DNS, etc.
- `.decodingFailed(underlying:)` — the server response could not be decoded.
- `.invalidBaseURL(_:)` — the configured URL was malformed.

Verification count mismatches throw **`VerificationError(expected:actual:)`**.

`WireMock` is a `Sendable` `struct` with value semantics that holds no mutable state — copy it freely
across tasks. All state lives on the server, so between tests reset the **server** (`resetAll()`), not
the client.

### Secured admin and HTTPS

If the admin API is secured (`--admin-api-basic-auth`), pass the credentials:

```swift
let wireMock = WireMock(baseURL: URL(string: "http://ci-host:8080")!,
                        authorization: .basic(username: "admin", password: "s3cret"))
// also: .bearer(token: "…") or .header(value: "…")
// There's also a failable convenience: WireMock(host:port:) -> WireMock? (nil on a bad host/port).
```

For HTTPS with a self-signed certificate, inject your own `URLSession` with a delegate that trusts the
dev cert (safer than disabling ATS globally): `WireMock(baseURL: url, session: mySession)`.

## Usage in tests

The client is **synchronous** (like Java WireMock): calls block, which is harmless in tests — you await
each step sequentially anyway. No `async`/`await` is needed in ordinary tests. Reset the **server** via
`resetAll()` (not the client — all state is there).

### Synchronous (the primary way)

```swift
final class CheckoutTests: XCTestCase {
    let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)

    override func setUpWithError() throws { try wireMock.resetAll() }

    func testCheckout() throws {
        try wireMock.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2])))
        // ... drive the app, then ...
        try wireMock.verify(getRequestedFor(urlEqualTo("/cart")))
    }
}
```

### From an `async` context (optional)

If you need to call the client **from `async` code**, wrap the call in `callAsync` — it offloads the
blocking work to a background queue and never blocks a Swift-concurrency (cooperative) thread:

```swift
func testCheckout() async throws {
    try await wireMock.callAsync { try $0.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2]))) }
    // ... drive the app, then ...
    try await wireMock.callAsync { try $0.verify(getRequestedFor(urlEqualTo("/cart"))) }
}
```

> Calling a synchronous method directly from an `async` context would block the cooperative thread — from
> `async`, use `callAsync`. In ordinary (synchronous) tests it isn't needed.

### Logging (Allure etc.)

All public types have a `description` in the Java WireMock `toString()` style: containers
(`StubMapping`, `LoggedRequest`, `ServeEvent`, `RequestPattern`, `ResponseDefinition`, `NearMiss`, …)
print as their JSON, leaf types as the bare value (`HTTPMethod` → `GET`, `Fault` → `EMPTY_RESPONSE`).
So `"\(stub)"` / `String(describing: loggedRequest)` give a readable string for step names and
attachments, not a reflection dump. Secrets don't leak: `AdminAuthorization`/`WireMock`/`AdminClient`
mask credentials in their descriptions.

```swift
Allure.step("Stub: \(stub)") { … }                 // the stub's JSON
XCTContext.runActivity(named: "\(loggedRequest)") { … }
```

## Continuous integration

The server is a Java process, so **it always runs on the CI host** — never inside an iOS simulator or
device (they can't spawn a JVM). Your tests only *connect* to it. Where exactly they connect depends on
the target:

| | iOS Simulator | Real device |
|---|---|---|
| Server address | `http://localhost:8080` (the simulator forwards localhost to the host) | `http://<host-LAN-IP>:8080` |
| Cleartext HTTP (ATS) | fine for localhost | needs an ATS exception or HTTPS |
| Local-network prompt | none | appears (breaks unattended runs) |
| Reliability | high | low — **prefer the simulator in CI** |

**Recommended pattern (host runs the server, tests connect):**

```bash
# 1. start WireMock on the CI host and wait for readiness
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 60); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 2. run the tests (iOS example)
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

Passing the URL to the app under test:

- **Integration/unit tests** (the test process makes the calls): read `ProcessInfo.environment["WIREMOCK_URL"]`
  (set via your `.xctestplan`) or default to `http://localhost:8080`.
- **UI tests** (a separate app process): `app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"`;
  the UI-test process configures stubs through a `WireMock` client on `localhost:8080`.

### XCUITest (verified on the simulator)

> **The server is a Java process that must run on the host** (as a jar or via Docker); it cannot launch
> inside the simulator/iOS test bundle. Start the server on the **host** — as a jar (works anywhere a JDK
> is present) **or** via Docker if available — and connect from the simulator.

Link the `WireMock` product into your **UI-test target**. The test runner (on the simulator) both
configures stubs and drives the app; `localhost:8080` inside the simulator reaches the server on the host:

```swift
import XCTest
import WireMock

final class PingUITests: XCTestCase {
    func testAppRendersStubbedResponse() throws {
        let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)
        try wireMock.resetAll()
        try wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"
        app.launch()

        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "pong"),
                               evaluatedWith: label)], timeout: 10)
        try wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }
}
```

The app under test reads `WIREMOCK_URL` from its environment and routes network requests there. Add
`NSAppTransportSecurity → NSAllowsLocalNetworking = true` to **both** the app **and** the UI-test target
so cleartext `http://localhost` is allowed. This exact flow is verified end-to-end on the iOS simulator
(see `Examples/WireMockXCUIDemo`).

Two patterns that this package's own test harness demonstrates (copy them into your test setup — they
live in `Tests/WireMockTests/TestSupport.swift`, not baked into the shipped library):

- **Fail, don't skip.** Have your test setup honour a `WIREMOCK_REQUIRED=1` environment variable so that
  in CI a missing/unhealthy server fails the build rather than silently skipping — a skip storm must never
  look green.
- **Serial only.** If integration suites share one server and reset it in `setUp`, they are not safe to
  run in parallel; don't enable `--parallel` without per-suite server isolation.

A ready-to-use GitHub Actions workflow is at
[`.github/workflows/ci.yml`](.github/workflows/ci.yml): macOS runners with the standalone jar running on
the host — unit + integration, an iOS build, and the iOS XCUITest example (all with readiness gates).

## Platform notes

- **The client** (`WireMock`, DSL, verification) runs on all Apple platforms and on Linux.
- It requires Java **or** Docker on the host that runs the server (the server itself is written in Java).

## Parity with Java WireMock

For the WireMock **3.x** line the client is at functional parity with the Java DSL + Admin API client:
every request-matcher operator, all `MappingBuilder`/`ResponseDefinitionBuilder` capabilities, all faults
and delay distributions, the full record/playback spec, scenarios, verification, near-misses, metadata,
settings and files are present, and the full `/__admin` endpoint set is covered — plus escape hatches for
anything not yet modelled.

The only capabilities that are **not available** are those structurally impossible from an out-of-process
HTTP client, and these are not defects:

- **Custom matchers/transformers written as JVM code** (`RequestMatcherExtension`, a custom
  `ResponseTransformer`) run *inside* the server. You can reference a server-installed extension by name
  and pass parameters, but you can't hand a Swift matcher closure to the Java engine.
- **In-process embedded server** — Java can run the server in the same JVM as the test; here it's an
  externally launched server (jar/Docker).
- **Typed `WireMockConfiguration`** — server startup configuration is passed as raw CLI `extraArgs`, not
  as a typed options object.
- **Numeric matchers** are available from WireMock 4.0+ (parity with Java, which also lacks them on 3.x).

### Known limitation: numeric precision in `JSONValue`

`JSONValue` (used in `jsonBody`, the `equalToJson` operand, `metadata`, transformer parameters) parses
numbers via `Int`/`Double`. Integers larger than `Int64` and fractions with precision above ~15–17
significant digits lose precision (Java/Jackson keep them as `BigInteger`/`BigDecimal`). In practice this
is rare in mock bodies. A precision-preserving `Decimal` variant was tried and reverted: on the older
Darwin Foundation, `JSONDecoder.decode(Decimal.self)` crashes the process instead of erroring cleanly. If
you need exact transfer of a large number, provide it via the string escape hatch `register(raw:)`.

## Testing this package

```bash
swift test                                          # golden-JSON unit tests always run

java -jar wiremock.jar --port 8080 --disable-banner & # start a server (or docker, if available)…
swift test                                          # …integration tests now run too
```

Integration tests are skipped automatically when the server is unavailable (override the target via
`WIREMOCK_URL=http://host:port`).

## License

Apache-2.0 — see the [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE) files.
