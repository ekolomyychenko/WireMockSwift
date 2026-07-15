# Changelog

All notable changes to WireMockSwift are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/ekolomyychenko/WireMockSwift/releases/tag/0.1.0
