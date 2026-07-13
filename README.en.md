# WireMockSwift

A native Swift client and DSL for [WireMock](https://wiremock.org) that closely mirrors the Java DSL
and Admin API.

It is **not** a reimplementation of the server — it drives a real WireMock server (run via Docker,
the standalone jar, or spawned from code) over its `/__admin/**` REST API. All request matching,
response templating, and JSON comparison are performed by the proven Java engine, so behaviour is
identical to Java WireMock; this package gives you a fluent, type-safe Swift way to configure and
verify it.

- ✅ Full request-matcher set, all response options, faults & delays, scenarios, proxying,
  record/playback, verification, near-misses, settings, files, metadata, and webhooks
- ✅ Covers the full documented `/__admin` Admin API surface
- ✅ `async/await`, `Sendable` under Swift 6 strict concurrency, macOS + Linux + iOS
- ✅ Golden-JSON + live-server test suites; a raw-JSON escape hatch for anything un-modelled

> **Status:** early development (0.x). The API may still change, a license is not yet chosen (see
> [License](#license)), and no release is tagged yet — so it is not yet resolvable as a versioned
> SwiftPM dependency. Verified against WireMock **3.13.2**.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Running a WireMock server](#running-a-wiremock-server)
- [Stubbing](#stubbing)
- [Request matchers](#request-matchers)
- [Responses](#responses)
- [Verification](#verification)
- [Scenarios](#scenarios-stateful-behaviour)
- [Proxying, faults & delays](#proxying-faults--delays)
- [Recording, files, metadata & settings](#recording-files-metadata--settings)
- [Webhooks](#webhooks)
- [Escape hatch](#escape-hatch)
- [Using it in tests](#using-it-in-tests)
- [Continuous integration](#continuous-integration)
- [Platform notes](#platform-notes)
- [Parity with Java WireMock](#parity-with-java-wiremock)
- [Testing this package](#testing-this-package)
- [License](#license)

## Requirements

- Swift 6.0+ (builds clean under `-strict-concurrency=complete`)
- A running WireMock **3.x** server (Docker image, standalone jar, or spawned via `WireMockServer`)
- Platforms: macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, and Linux. The `WireMockServer` process
  launcher is macOS/Linux only (see [Platform notes](#platform-notes)).

## Installation

Swift Package Manager — add to `Package.swift` (once a release is tagged; until then depend on a
branch or revision):

```swift
.package(url: "https://github.com/ekolomyychenko/WireMockSwift.git", from: "0.1.0")
```

and add the product to your (test) target:

```swift
.testTarget(name: "MyAppTests", dependencies: [.product(name: "WireMock", package: "WireMockSwift")])
```

## Quick start

Start a server — the standalone jar needs only a JDK and works anywhere (see
[below](#running-a-wiremock-server) for all options, including restricted/corporate machines):

```bash
java -jar wiremock-standalone-3.13.2.jar --port 8080
```

Stub a response, exercise it, and verify it was called:

```swift
import WireMock

let wireMock = WireMock(host: "localhost", port: 8080)

try await wireMock.stubFor(
    get(urlEqualTo("/hello"))
        .willReturn(okForJson(["message": "world"]))
)

// ... your code under test calls http://localhost:8080/hello ...

try await wireMock.verify(getRequestedFor(urlEqualTo("/hello")))

try await wireMock.resetAll()   // clean state between tests
```

## Running a WireMock server

You have three options; pick by your environment and where your tests run.

**1. Standalone jar (recommended, most portable)** — needs only a JDK, no Docker, no install step.
Download it once from Maven Central and, ideally, **vendor it in your repo** so builds are
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

**3. From code (`WireMockServer`)** — the test process launches and tears the server down itself,
using whichever of the above is available. macOS/Linux host processes only (not inside an iOS
simulator/device — see [Platform notes](#platform-notes)):

```swift
let server = WireMockServer(port: 8080, launch: .jar(path: "wiremock.jar"))
// or: WireMockServer(port: 8080, launch: .docker(image: "wiremock/wiremock:3.13.2"))
try await server.start()          // launches the process, polls the admin API until it responds
defer { server.stop() }

try await server.client.stubFor(get(anyUrl).willReturn(ok()))
```

> **Restricted / corporate environments.** Prefer the **jar** — it only needs a JDK (commonly already
> present for Android/JVM tooling) and can be committed to the repo, so no Docker and no network are
> required. If your machine allows neither Docker nor a JDK, run WireMock once on a shared/CI host and
> point every client at it over the network with `WireMock(baseURL:)` — the server does not have to be
> local.

> **The port is not fixed.** `8080` in the examples is only a default. Run WireMock on any port
> (`--port <N>`) and point the client at it via `WireMock(port:)` / `WireMock(baseURL:)` or the
> `WIREMOCK_URL` env var. Nothing is pinned to 8080 — you can run several instances on different
> ports (e.g. for parallel suites).

## Stubbing

Stubs are built with a fluent, value-typed DSL that mirrors WireMock's Java `MappingBuilder`:

```swift
try await wireMock.stubFor(
    post(urlPathEqualTo("/things"))
        .withHeader("Content-Type", equalTo("application/json"))
        .withQueryParam("verbose", equalTo("true"))
        .withRequestBody(matchingJsonPath("$.name"))
        .atPriority(1)
        .withMetadata(["team": "payments"])
        .willReturn(okForJson(["id": 1]))
)
```

Entry points exist for every method — `get`, `post`, `put`, `patch`, `delete`, `head`, `options`,
`trace`, `any`, and `request(_:_:)` for anything else: `request(.patch, urlEqualTo("/x"))`, or, since
`HTTPMethod` is `ExpressibleByStringLiteral`, a custom verb as a string — `request("REPORT", urlEqualTo("/x"))`.
URLs are matched with `urlEqualTo`, `urlMatching` (regex), `urlPathEqualTo`, `urlPathMatching`,
`urlPathTemplate`, or `anyUrl`.

Request criteria: `withHeader` / `withoutHeader`, `withQueryParam`, `withCookie`, `withPathParam`,
`withFormParam`, `withRequestBody`, `withMultipartRequestBody`, `withBasicAuth(username:password:)`,
`withHost` / `withPort` / `withScheme`.

## Request matchers

Every matcher is available both as a `StringValuePattern` factory (`.equalTo(…)`) and as a free
function (`equalTo(…)`) mirroring the Java DSL:

```swift
equalTo("text")                      // + caseInsensitive: / equalToIgnoreCase(_:)
containing("part")                   // notContaining(_:)
matching("[0-9]+")                   // notMatching(_:) (regex)
absent                               // header/param must be absent
anything                             // matches any value
binaryEqualTo("aGk=")                // base64 byte comparison

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
hasExactly(equalTo("1"), equalTo("2"))           // repeated multi-value params
includes(containing("red"))
```

A bare string literal is shorthand for `.equalTo`, so `withHeader("Accept", "application/json")` and
`withHeader("Accept", equalTo("application/json"))` are equivalent.

> The free functions carry the **common** parameters; the **advanced options** (XML placeholders,
> datetime offset/truncation, XPath sub-matchers, numeric comparisons) live only on the
> `StringValuePattern.` static factories.

> **Numeric matchers** (`StringValuePattern.equalToNumber/greaterThan/greaterThanOrEqual/lessThan/
> lessThanOrEqual`) require **WireMock 4.0+** — WireMock 3.x rejects them with HTTP 422. They are
> exposed only as explicit factories, never as free functions. On 3.x, match numbers with a JSONPath
> predicate: `matchingJsonPath("$[?(@.age > 5)]")`.

## Responses

```swift
ok()                                  // 200
ok("plain body")
okForJson(["id": 1])                  // 200 + application/json
okForContentType("text/csv", "a,b,c") // 200 + given Content-Type
jsonResponse(["error": "nope"], status: 422)
created(); noContent(); badRequest(); notFound(); serverError()   // and more
temporaryRedirect(to: "/new"); permanentRedirect(to: "/new"); seeOther("/other")
status(418)

aResponse()
    .withStatus(200)
    .withStatusMessage("OK")
    .withHeader("X-Trace", "abc")          // multi-value: .withHeader("Set-Cookie", ["a=1", "b=2"])
    .withJsonBody(["ok": true])            // or withBody / withBase64Body / withBodyFile
    .withTransformers("response-template") // server-side Handlebars templating
    .withTransformerParameter("name", "Bob")
```

## Verification

```swift
// At least once:
try await wireMock.verify(postRequestedFor(urlEqualTo("/things")))

// Exact / relative counts — throws VerificationError if unsatisfied:
try await wireMock.verify(.exactly(3), getRequestedFor(urlEqualTo("/ping")))
try await wireMock.verify(.moreThanOrExactly(1), getRequestedFor(urlEqualTo("/ping")))
try await wireMock.verify(.lessThan(5), getRequestedFor(urlEqualTo("/ping")))

// Journal queries:
let count   = try await wireMock.count(getRequestedFor(urlEqualTo("/ping")))
let matched = try await wireMock.findAll(postRequestedFor(urlEqualTo("/things")))
let events  = try await wireMock.getAllServeEvents()
let unmatched = try await wireMock.getUnmatchedRequests()
let nearMisses = try await wireMock.findNearMissesForAllUnmatched()

try await wireMock.resetRequests()                                   // clear the journal
try await wireMock.removeServeEvents(matching: getRequestedFor(urlEqualTo("/ping")))
```

`RequestPatternBuilder` supports the same criteria as stubbing (`withHeader`, `withoutHeader`,
`withQueryParam`, `withCookie`, `withRequestBody`, `withBasicAuth`, etc.).

## Scenarios (stateful behaviour)

```swift
try await wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("Started").willSetStateTo("step-2")
        .willReturn(ok("first"))
)
try await wireMock.stubFor(
    get(urlEqualTo("/next")).inScenario("flow")
        .whenScenarioStateIs("step-2").willReturn(ok("second"))
)

let scenarios = try await wireMock.getAllScenarios()
try await wireMock.setScenarioState(name: "flow", state: "step-2")
try await wireMock.resetScenario(name: "flow")     // one scenario
try await wireMock.resetAllScenarios()             // all
```

## Proxying, faults & delays

```swift
// Proxy unmatched/selected traffic to a real backend:
try await wireMock.stubFor(
    any(urlPathMatching("/api/.*")).willReturn(
        aResponse().proxiedFrom("https://api.example.com")
            .withProxyUrlPrefixToRemove("/api")
            .withAdditionalProxyRequestHeader("X-From", "wiremock")
    )
)

// Faults:
aResponse().withFault(.connectionResetByPeer)   // .emptyResponse, .malformedResponseChunk, .randomDataThenClose

// Delays:
aResponse().withFixedDelay(500)
aResponse().withLogNormalRandomDelay(median: 90, sigma: 0.1)
aResponse().withUniformRandomDelay(lower: 15, upper: 25)
aResponse().withChunkedDribbleDelay(numberOfChunks: 5, totalDuration: 1000)

// Global (applies to every response):
try await wireMock.setGlobalFixedDelay(200)
```

## Recording, files, metadata & settings

```swift
try await wireMock.startRecording(targetBaseUrl: "https://api.example.com")
// ... drive traffic through the proxy ...
let generated = try await wireMock.stopRecording()   // [StubMapping]
let status = try await wireMock.getRecordingStatus()
let snapshot = try await wireMock.takeSnapshot()
// ⚠️ `targetBaseUrl` must point at a SEPARATE upstream — pointing it back at the
//    same WireMock instance forms a self-proxy loop that hangs.

// __files:
try await wireMock.putFile(named: "body.json", text: #"{"hi":true}"#, contentType: "application/json")
let names = try await wireMock.listFiles()
let data = try await wireMock.getFile(named: "body.json")
try await wireMock.deleteFile(named: "body.json")
// Note: WireMock 3.x does not percent-decode path segments, so scenario and
// __files names should be URL-safe — a name with spaces/`%`/unicode is stored
// and addressed under its encoded form (e.g. "a b.json" → "a%20b.json").

// Metadata & bulk import:
let stubs = try await wireMock.findStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try await wireMock.removeStubsByMetadata(matchingJsonPath("$.team", equalTo("payments")))
try await wireMock.importMappings([stub1, stub2])

// Settings:
try await wireMock.updateGlobalSettings(GlobalSettings(fixedDelay: 100))
let settings = try await wireMock.getGlobalSettings()   // lossless: unknown keys preserved in .extended
let health = try await wireMock.getHealth()
```

## Webhooks

Fire an outbound HTTP call when a stub is matched (built-in `webhook` listener):

```swift
try await wireMock.stubFor(
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

Anything not yet modelled by the typed DSL (extension matchers, future server features) can still be
registered from raw JSON, so you are never blocked:

```swift
try await wireMock.register(raw: #"""
{ "request": { "method": "GET", "url": "/raw" },
  "response": { "status": 200, "body": "ok" } }
"""#)

try await wireMock.register(json: ["request": ["method": "GET", "url": "/x"],
                                   "response": ["status": 204]])
```

`StringValuePattern([...])` likewise builds an arbitrary matcher from raw fields.

## Errors & concurrency

Every call throws a typed **`WireMockError`** (all `CustomStringConvertible`):

- `.unexpectedStatus(code:body:)` — the server rejected the request (e.g. HTTP 422 for a 4.x-only
  matcher on a 3.x server); the response body is included.
- `.transport(underlying:)` — connection refused, timeout, DNS, etc.
- `.decodingFailed(underlying:)` — the server response couldn't be decoded.
- `.invalidBaseURL(_:)` — the configured URL was malformed.

Verification count mismatches throw **`VerificationError(expected:actual:)`**.

`WireMock` is a `Sendable` value-type `struct` holding no mutable state — copy it freely across tasks.
All state lives on the server, so reset **the server** (`resetAll()`), not the client, between tests.
(`WireMockServer`, the process launcher, is a reference type and `@unchecked Sendable`; use one
instance per server.)

## Using it in tests

The client is `async` first. Reset state per test for isolation:

```swift
final class CheckoutTests: XCTestCase {
    let wireMock = WireMock(host: "localhost", port: 8080)

    override func setUp() async throws { try await wireMock.resetAll() }

    func testCheckout() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/cart")).willReturn(okForJson(["items": 2])))
        // ... exercise the app, then ...
        try await wireMock.verify(getRequestedFor(urlEqualTo("/cart")))
    }
}
```

Inside a synchronous test body, bridge with `WireMockSync.run` (blocks with a timeout; never call it
from an `async` context):

```swift
let stub = try WireMockSync.run { try await wireMock.stubFor(get(anyUrl).willReturn(ok())) }
```

## Continuous integration

The server is a Java process, so **it always runs on the CI host** — never inside an iOS simulator or
device (those can't spawn a JVM). Your tests only *connect* to it. Where they connect depends on the
target:

| | iOS Simulator | Real device |
|---|---|---|
| Server address | `http://localhost:8080` (simulator forwards localhost to the host) | `http://<host-LAN-IP>:8080` |
| Cleartext HTTP (ATS) | fine for localhost | needs an ATS exception or HTTPS |
| Local-network prompt | none | appears (breaks unattended runs) |
| Reliability | high | low — **prefer the simulator in CI** |

**Recommended pattern (host launches the server, tests connect):**

```bash
# 1. start WireMock on the CI host and wait for readiness
java -jar wiremock-standalone-3.13.2.jar --port 8080 --disable-banner &
for i in $(seq 1 60); do curl -sf http://localhost:8080/__admin/health && break; sleep 1; done

# 2. run tests (iOS example)
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

Passing the URL to the app under test:

- **Integration/unit tests** (test process makes the calls): read `ProcessInfo.environment["WIREMOCK_URL"]`
  (set it via your `.xctestplan`) or default to `http://localhost:8080`.
- **UI tests** (separate app process): `app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"`;
  the UI-test process configures stubs via the `WireMock` client on `localhost:8080`.

### XCUITest (verified on the simulator)

> **`WireMockServer` cannot be used from an iOS test bundle** (it spawns a `java`/`docker`
> subprocess and is compiled out on iOS). Start the server on the **host** — as a jar (works
> everywhere with just a JDK) **or** via Docker if available — and connect from the simulator.

Link the `WireMock` product into your **UI-test target**. The test runner (on the simulator) both
configures stubs and drives the app; `localhost:8080` inside the simulator reaches the host server:

```swift
import XCTest
import WireMock

final class PingUITests: XCTestCase {
    func testAppRendersStubbedResponse() async throws {
        let wireMock = WireMock(baseURL: URL(string: "http://localhost:8080")!)
        try await wireMock.resetAll()
        try await wireMock.stubFor(get(urlEqualTo("/ping")).willReturn(ok("pong")))

        let app = XCUIApplication()
        app.launchEnvironment["WIREMOCK_URL"] = "http://localhost:8080"
        app.launch()

        let label = app.staticTexts["result"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        await fulfillment(of: [expectation(for: NSPredicate(format: "label == %@", "pong"),
                                           evaluatedWith: label)], timeout: 10)
        try await wireMock.verify(getRequestedFor(urlEqualTo("/ping")))
    }
}
```

The app under test reads `WIREMOCK_URL` from its environment and points its networking there.
Add `NSAppTransportSecurity → NSAllowsLocalNetworking = true` to **both** the app and the UI-test
target so cleartext `http://localhost` is allowed. This exact flow is verified end-to-end on an iOS
Simulator (see `Examples/WireMockXCUIDemo`).

Two patterns this package's own test harness demonstrates (copy them into your test setup — they are
in `Tests/WireMockTests/TestSupport.swift`, not built into the shipped library):

- **Fail, don't skip.** Have your test setup honour a `WIREMOCK_REQUIRED=1` env var so that in CI a
  missing/unhealthy server fails the build instead of silently skipping — a skip-storm must never look
  green.
- **Serial only.** If integration suites share one server and reset it in `setUp`, they are not
  parallel-safe; don't enable `--parallel` without per-suite server isolation.

A ready-to-use GitHub Actions workflow (Linux service container + macOS jar, with a readiness gate)
lives in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Platform notes

- The **client** (`WireMock`, the DSL, verification) works on all Apple platforms and Linux.
- **`WireMockServer`** (launching the server from code) is compiled only on macOS/Linux — it spawns a
  `java`/`docker` subprocess, which is impossible on an iOS/tvOS/watchOS device or simulator. There,
  run the server on your host/CI machine and point the client at it via `WireMock(baseURL:)`.
- Requires Java **or** Docker on the host that runs the server (the server itself is Java).

## Parity with Java WireMock

For the WireMock **3.x** line, the client is at functional parity with the Java client DSL + Admin
API: every request-matcher operator, all `MappingBuilder`/`ResponseDefinitionBuilder` capabilities,
all faults and delay distributions, the full record/playback spec, scenarios, verification,
near-misses, metadata, settings, and files are present, and the complete `/__admin` endpoint set is
covered — plus escape hatches for anything un-modelled.

The only capabilities that are **not** available are those structurally impossible from an
out-of-process HTTP client, and are not defects:

- **Custom matchers/transformers written as JVM code** (`RequestMatcherExtension`, custom
  `ResponseTransformer`) run *inside* the server. You can reference a server-installed extension by
  name and pass parameters, but you cannot supply Swift matcher code to the Java engine.
- **In-process embedded server** — Java can run the server in the same JVM as the test; here it is an
  external process (`WireMockServer`) or a separately-run container.
- **Typed `WireMockConfiguration`** — server-launch tuning is passed through as raw CLI `extraArgs`
  rather than a typed options object.
- **Numeric matchers** are WireMock 4.0+ (parity with Java, which also lacks them on 3.x).

## Testing this package

```bash
swift test                                          # golden-JSON unit tests always run

java -jar wiremock.jar --port 8080 --disable-banner & # start a server (or docker, if available)…
swift test                                          # …now the integration tests run too
```

Integration tests auto-skip when no server is reachable (override the target with
`WIREMOCK_URL=http://host:port`). Set `WIREMOCK_JAR=/path/to/wiremock-standalone.jar` to run the
`WireMockServer` boot test.

## License

TBD.
