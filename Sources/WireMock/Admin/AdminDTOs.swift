import Foundation

/// Envelope returned by `GET /__admin/mappings`.
struct ListStubMappingsResult: Decodable {
    /// `total` is optional so a `meta` object that omits it (a newer/other
    /// server shape) doesn't fail the whole decode — callers fall back to the
    /// returned mapping count.
    struct Meta: Decodable { let total: Int? }
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

/// Response of `GET /__admin/files`. The server has returned both a bare array
/// (`["a.json"]`) and a `{ "files": [...] }` wrapper across versions; accept
/// either so a version bump doesn't break `listFiles()`.
struct FilesResult: Decodable {
    let files: [String]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([String].self) {
            files = array
            return
        }
        struct Wrapper: Decodable { let files: [String] }
        files = try Wrapper(from: decoder).files
    }
}
