import Foundation

/// Fluent builder for a `StubMapping`. Mirrors WireMock's `MappingBuilder`:
///
/// ```swift
/// let stub = post(urlEqualTo("/things"))
///     .withHeader("Content-Type", equalTo("application/json"))
///     .withRequestBody(matchingJsonPath("$.name"))
///     .atPriority(1)
///     .willReturn(okForJson(["id": 1]))
/// ```
///
/// Like Java's `BasicMappingBuilder`, the request-matching methods delegate to a
/// wrapped `RequestPatternBuilder` so that logic lives in exactly one place.
public struct MappingBuilder: Sendable {
    /// Builds the request half. Single source of truth for request criteria.
    private var requestBuilder: RequestPatternBuilder
    /// Everything else (response, priority, scenario, metadata, …). Its own
    /// `request` field is unused — the request comes from `requestBuilder`.
    private var meta: StubMapping

    init(method: HTTPMethod, url: UrlPattern) {
        self.requestBuilder = RequestPatternBuilder(method: method, url: url)
        self.meta = StubMapping(request: RequestPattern(), response: ResponseDefinition())
    }

    /// The assembled mapping: `meta` with its request replaced by the one built
    /// from the delegated `RequestPatternBuilder`.
    public var mapping: StubMapping {
        var result = meta
        result.request = requestBuilder.pattern
        return result
    }

    private func delegatingRequest(_ transform: (RequestPatternBuilder) -> RequestPatternBuilder) -> Self {
        var copy = self
        copy.requestBuilder = transform(copy.requestBuilder)
        return copy
    }

    private func mutating(_ transform: (inout StubMapping) -> Void) -> Self {
        var copy = self
        transform(&copy.meta)
        return copy
    }

    // MARK: Request criteria (delegated to RequestPatternBuilder)

    public func withHeader(_ name: String, _ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withHeader(name, pattern) }
    }

    /// Requires the header to be absent.
    public func withoutHeader(_ name: String) -> Self {
        delegatingRequest { $0.withoutHeader(name) }
    }

    public func withQueryParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withQueryParam(name, pattern) }
    }

    public func withCookie(_ name: String, _ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withCookie(name, pattern) }
    }

    public func withPathParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withPathParam(name, pattern) }
    }

    public func withFormParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withFormParam(name, pattern) }
    }

    public func withRequestBody(_ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withRequestBody(pattern) }
    }

    public func withBasicAuth(username: String, password: String) -> Self {
        delegatingRequest { $0.withBasicAuth(username: username, password: password) }
    }

    public func withMultipartRequestBody(_ part: MultipartValuePattern) -> Self {
        delegatingRequest { $0.withMultipartRequestBody(part) }
    }

    public func withHost(_ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withHost(pattern) }
    }

    public func withPort(_ port: Int) -> Self {
        delegatingRequest { $0.withPort(port) }
    }

    public func withScheme(_ scheme: String) -> Self {
        delegatingRequest { $0.withScheme(scheme) }
    }

    /// Matches on the client's IP address.
    public func withClientIp(_ pattern: StringValuePattern) -> Self {
        delegatingRequest { $0.withClientIp(pattern) }
    }

    // MARK: Serve-event listeners

    /// Attaches a serve-event listener that fires when this stub is matched.
    /// For the built-in webhook, prefer `withWebhook(_:)`.
    public func withServeEventListener(_ listener: ServeEventListenerDefinition) -> Self {
        mutating {
            var listeners = $0.serveEventListeners ?? []
            listeners.append(listener)
            $0.serveEventListeners = listeners
        }
    }

    /// Convenience for the built-in `webhook` listener.
    public func withWebhook(_ webhook: WebhookDefinition) -> Self {
        withServeEventListener(webhook.asServeEventListener())
    }

    // MARK: Mapping metadata

    public func atPriority(_ priority: Int) -> Self {
        mutating { $0.priority = priority }
    }

    public func withId(_ id: UUID) -> Self {
        mutating { $0.id = id }
    }

    public func withName(_ name: String) -> Self {
        mutating { $0.name = name }
    }

    public func withMetadata(_ metadata: [String: JSONValue]) -> Self {
        mutating { $0.metadata = metadata }
    }

    public func persistent(_ isPersistent: Bool = true) -> Self {
        mutating { $0.persistent = isPersistent }
    }

    // MARK: Scenarios

    public func inScenario(_ name: String) -> Self {
        mutating { $0.scenarioName = name }
    }

    public func whenScenarioStateIs(_ state: String) -> Self {
        mutating { $0.requiredScenarioState = state }
    }

    public func willSetStateTo(_ state: String) -> Self {
        mutating { $0.newScenarioState = state }
    }

    // MARK: Response

    public func willReturn(_ response: ResponseDefinitionBuilder) -> Self {
        mutating { $0.response = response.definition }
    }

    public func build() -> StubMapping { mapping }
}
