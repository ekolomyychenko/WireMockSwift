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
public struct MappingBuilder: Sendable {
    public private(set) var mapping: StubMapping

    init(method: HTTPMethod, url: UrlPattern) {
        var request = RequestPattern()
        request.method = method
        url.apply(to: &request)
        self.mapping = StubMapping(request: request, response: ResponseDefinition())
    }

    private func mutating(_ transform: (inout StubMapping) -> Void) -> Self {
        var copy = self
        transform(&copy.mapping)
        return copy
    }

    // MARK: Request criteria

    public func withHeader(_ name: String, _ pattern: StringValuePattern) -> Self {
        mutating {
            var headers = $0.request.headers ?? [:]
            headers[name] = pattern
            $0.request.headers = headers
        }
    }

    /// Requires the header to be absent.
    public func withoutHeader(_ name: String) -> Self {
        withHeader(name, .absent)
    }

    public func withQueryParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        mutating {
            var params = $0.request.queryParameters ?? [:]
            params[name] = pattern
            $0.request.queryParameters = params
        }
    }

    public func withCookie(_ name: String, _ pattern: StringValuePattern) -> Self {
        mutating {
            var cookies = $0.request.cookies ?? [:]
            cookies[name] = pattern
            $0.request.cookies = cookies
        }
    }

    public func withPathParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        mutating {
            var params = $0.request.pathParameters ?? [:]
            params[name] = pattern
            $0.request.pathParameters = params
        }
    }

    public func withFormParam(_ name: String, _ pattern: StringValuePattern) -> Self {
        mutating {
            var params = $0.request.formParameters ?? [:]
            params[name] = pattern
            $0.request.formParameters = params
        }
    }

    public func withRequestBody(_ pattern: StringValuePattern) -> Self {
        mutating {
            var patterns = $0.request.bodyPatterns ?? []
            patterns.append(pattern)
            $0.request.bodyPatterns = patterns
        }
    }

    public func withBasicAuth(username: String, password: String) -> Self {
        mutating { $0.request.basicAuthCredentials = BasicAuthCredentials(username: username, password: password) }
    }

    public func withMultipartRequestBody(_ part: MultipartValuePattern) -> Self {
        mutating {
            var parts = $0.request.multipartPatterns ?? []
            parts.append(part)
            $0.request.multipartPatterns = parts
        }
    }

    public func withHost(_ pattern: StringValuePattern) -> Self {
        mutating { $0.request.host = pattern }
    }

    public func withPort(_ port: Int) -> Self {
        mutating { $0.request.port = port }
    }

    public func withScheme(_ scheme: String) -> Self {
        mutating { $0.request.scheme = scheme }
    }

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
