# Changelog

All notable changes to WireMockSwift are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-16

### Added

- **Request expectations (`expect(...)`)** — an additive, BDD/RestAssured-style layer over the
  existing verification API for asserting on outgoing requests in detail. Fluent `to*` / `toNot*`
  checks (headers, query params, cookies, form params, bearer/basic auth, and a full body family:
  `toHaveJsonPath` (existence and value-at-path), `toHaveJsonBody` full / partial / raw / file / schema, named text
  overloads `toHaveBody(equalTo:/containing:/matching:)`, `toHaveEmptyBody`/`toHaveNonEmptyBody`,
  `toHaveXmlBody` with options, and `toHaveBody(matchingXPath:)` with namespaces/sub-matcher) that
  refine the pattern and re-verify server-side; `CountSpec`
  (`.once`/`.never`/`.times`/`.atLeast`/`.atMost`/`.moreThan`/`.lessThan`/`.between`);
  `toHaveExactlyQueryParams` (client-side, fails on stray params); and terminals
  `single`/`first`/`last` returning a typed `CapturedRequest` (with header/query/cookie/
  body accessors), `all` returning `[CapturedRequest]`, and `extract` returning a `RequestExtractor`
  with `extract().jsonPath(...)` for correlating values across requests. Failures throw
  `RequestExpectationError` with a near-miss diff (shortfall) or a dump of every matching request
  ("too many"). The JSON-from-file overload takes an optional `subdirectory:` (for `.copy`'d resource
  folders) and reports read failures as `RequestExpectationError`, consistent with the bundle overload.
  Purely additive — `verify(...)` and `VerificationError` are unchanged.
- **Identity-provider assertion helpers** — additive helpers aimed at OAuth 2.0 / OIDC flows.
  Presence-only overloads `toHaveHeader/toHaveQueryParam/toHaveCookie/toHaveFormParam(_ name)`
  ("key present, any value" — e.g. `state`/`nonce`/`code_verifier`). Form-body extraction:
  `CapturedRequest.formParams(_:)`/`formParam(_:)` and `RequestExtractor.formParam(_:)`, which parse
  the `application/x-www-form-urlencoded` body so you can correlate the token endpoint (PKCE
  `code_verifier`, `redirect_uri` parity). `WireMock.verifyInOrder([RequestPatternBuilder])` — a
  cross-pattern ordering check (e.g. `authorize → token → userinfo`) judged on the journal's
  `loggedDate`, throwing `SequenceVerificationError`; matching stays server-side, only the timeline is
  compared (millisecond resolution). `JWT(decoding:)` — a **signature-unverified** JWT decoder
  exposing `header`/`payload`/`claim(_:)`, with `RequestExtractor` conveniences `bearerJWT()`,
  `jwt(header:)`, `jwt(formParam:)`, `jwt(queryParam:)` for `client_assertion`, `id_token_hint`, DPoP,
  and JWT bearer tokens. Signature verification is intentionally out of scope (test assertions on
  outgoing requests inspect claims, not signatures). `toHaveExactlyFormParams` mirrors
  `toHaveExactlyQueryParams` for the form body (the prime place to prove no extra field — e.g. a
  `client_secret` — leaked into the token request). Purely additive.
  - `toNot*` checks now assert **no** matching request carries the field (the count of requests that
    *do* must be zero), instead of the weaker "at least one request lacked it" — the latter silently
    passed when a clean duplicate request coexisted with a leaking one (a security-negative footgun).
  - `toNotHaveFormParam` additionally scans the captured request bodies client-side: WireMock only
    parses `formParameters` when the request carried an `application/x-www-form-urlencoded` content
    type, so a form-encoded body sent without it would otherwise slip past the server-only negative and
    leak the param (e.g. `client_secret`).
  - Form/query-param decoding parses by hand instead of via `URLComponents.percentEncodedQuery`, whose
    setter *trapped the whole process* on a stray `%` or `#`; a malformed escape is now left verbatim.
  - `verifyInOrder` decides ordering by exhaustive search over the per-step candidates, so overlapping
    step patterns with same-millisecond timestamps no longer produce a false failure.
  - A positive field check (`toHaveHeader`/`toHaveQueryParam`/…) chained after an upper-bound-only count
    spec (`.atMost`/`.lessThan`, satisfied by 0) now requires the narrowed count to be at least one, so
    the check can no longer vacuously pass when the field is entirely absent.

## [0.1.0] - 2026-07-15

First public release. A native Swift client and DSL for [WireMock](https://wiremock.org)
that closely mirrors the Java DSL and Admin API. It does **not** reimplement the server —
it drives a real WireMock server (Docker or standalone jar) over its `/__admin/**` REST API,
so all request matching, response templating and JSON comparison run on the proven Java engine.

Verified against WireMock **3.13.2**.

### Added

- **Stubbing DSL** — full set of request matchers (URL/path/method, query & form params,
  headers, cookies, basic auth, client IP, body: JSON/JSONPath/XPath/XML/regex/binary/multipart,
  logical `and`/`or`/`not` and custom matchers) with a fluent `MappingBuilder`.
- **Responses** — status, headers, body (string/Data/JSON/base64/file), templating and
  transformers, per-response and global delays (fixed, uniform, lognormal, chunked dribble),
  faults, and helper shortcuts (`ok`, `okJson`, `badRequestEntity`, …).
- **Verification** — `verify`, count strategies, `findAll`/`getServeEvents`, and Java-parity
  near-miss diagnostics folded into `VerificationError`.
- **Scenarios** — stateful stubbing with scenario states and transitions.
- **Proxying** — dedicated proxy response builder (`proxiedFrom`) with additional/removed
  request headers, matching the Java `ProxyResponseDefinitionBuilder`.
- **Recording & snapshots** — start/stop recording, `takeSnapshot`, record filters and options.
- **Webhooks / post-serve actions**, files (`__files`), stub metadata, and global settings.
- **Admin API coverage** — the full documented `/__admin` surface, plus a raw-JSON escape hatch
  (`register(raw:)`, `AdminClient.rawRequest`) for anything not yet modelled.
- **Synchronous client** (like Java WireMock) with an optional `callAsync` bridge for
  `async` contexts. `Sendable` under Swift 6 strict concurrency.
- **Allure-friendly logging** — `CustomStringConvertible` on all public types, mirroring
  Java `toString()` (JSON for containers).
- **Platforms** — macOS 12+ and iOS 15+ (iOS 15 is a compile floor; tested from iOS 16 up,
  including an iPad idiom, in CI).

[0.2.0]: https://github.com/ekolomyychenko/WireMockSwift/releases/tag/0.2.0
[0.1.0]: https://github.com/ekolomyychenko/WireMockSwift/releases/tag/0.1.0
