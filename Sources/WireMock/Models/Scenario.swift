import Foundation

/// A WireMock scenario and its current state.
public struct Scenario: Codable, Sendable, Hashable {
    public var id: String?
    public var name: String
    public var state: String?
    public var possibleStates: [String]?
}

struct GetScenariosResult: Decodable {
    let scenarios: [Scenario]
}
