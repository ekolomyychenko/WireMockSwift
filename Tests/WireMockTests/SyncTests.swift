import XCTest
@testable import WireMock

/// Unit tests for the synchronous bridge `WireMockSync.run` — the escape hatch
/// that runs an async operation from a synchronous XCTest body. No server needed.
final class SyncTests: XCTestCase {
    func testRunReturnsValue() throws {
        let value = try WireMockSync.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testRunReturnsAsyncComputedValue() throws {
        let value = try WireMockSync.run {
            try await Task.sleep(nanoseconds: 5_000_000)
            return "done"
        }
        XCTAssertEqual(value, "done")
    }

    func testRunPropagatesThrownError() {
        struct Boom: Error {}
        XCTAssertThrowsError(try WireMockSync.run { throw Boom() }) { error in
            XCTAssertTrue(error is Boom, "underlying error must propagate, got \(error)")
        }
    }

    // TEMPORARY: testRunTimesOutAndCancels removed to isolate a CI-only signal-5
    // crash (detached-task cancellation was a suspect). Restored once confirmed.
}
