import Foundation

/// Envelope returned by `GET /__admin/mappings`.
struct ListStubMappingsResult: Decodable {
    struct Meta: Decodable { let total: Int }
    let mappings: [StubMapping]
    /// Pagination metadata; `total` is the full mapping count.
    let meta: Meta?
}

/// Envelope returned by `POST /__admin/requests/count`. `count` is `-1` when
/// the request journal is disabled.
struct CountResult: Decodable {
    let count: Int
    let requestJournalDisabled: Bool?
}
