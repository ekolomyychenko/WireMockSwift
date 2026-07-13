import Foundation

/// Envelope returned by `GET /__admin/mappings`.
struct ListStubMappingsResult: Decodable {
    let mappings: [StubMapping]
}

/// Envelope returned by `POST /__admin/requests/count`.
struct CountResult: Decodable {
    let count: Int
}
