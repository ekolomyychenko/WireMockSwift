import Foundation

/// A WireMock scenario and its current state.
public struct Scenario: Codable, Sendable, Hashable {
    public var id: String?
    public var name: String
    public var state: String?
    public var possibleStates: [String]?
    /// The stub mappings belonging to this scenario (as returned by
    /// `GET /__admin/scenarios`).
    public var mappings: [StubMapping]?
}

struct GetScenariosResult: Decodable {
    let scenarios: [Scenario]
}
