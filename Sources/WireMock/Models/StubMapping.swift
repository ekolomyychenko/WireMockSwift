import Foundation

/// A complete WireMock stub mapping: a request pattern paired with the
/// response to serve, plus optional scenario, priority and metadata.
///
/// This is the payload `POST`/`PUT`ed to `/__admin/mappings`, and the shape
/// returned when listing mappings.
public struct StubMapping: Codable, Sendable, Hashable {
    public var id: UUID?
    public var name: String?
    public var priority: Int?
    public var scenarioName: String?
    public var requiredScenarioState: String?
    public var newScenarioState: String?
    public var request: RequestPattern
    public var response: ResponseDefinition
    public var metadata: [String: JSONValue]?
    public var persistent: Bool?
    public var serveEventListeners: [ServeEventListenerDefinition]?
    /// Legacy post-serve actions (superseded by `serveEventListeners`). Modelled
    /// so a fetched mapping that carries them round-trips losslessly.
    public var postServeActions: [ServeEventListenerDefinition]?

    public init(
        id: UUID? = nil,
        name: String? = nil,
        priority: Int? = nil,
        scenarioName: String? = nil,
        requiredScenarioState: String? = nil,
        newScenarioState: String? = nil,
        request: RequestPattern = RequestPattern(),
        response: ResponseDefinition = ResponseDefinition(),
        metadata: [String: JSONValue]? = nil,
        persistent: Bool? = nil,
        serveEventListeners: [ServeEventListenerDefinition]? = nil,
        postServeActions: [ServeEventListenerDefinition]? = nil
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.scenarioName = scenarioName
        self.requiredScenarioState = requiredScenarioState
        self.newScenarioState = newScenarioState
        self.request = request
        self.response = response
        self.metadata = metadata
        self.persistent = persistent
        self.serveEventListeners = serveEventListeners
        self.postServeActions = postServeActions
    }
}
