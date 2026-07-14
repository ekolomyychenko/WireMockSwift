import XCTest
@testable import WireMock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Error-path coverage: unmatched requests, admin calls that must surface
/// `WireMockError.unexpectedStatus`, and client-side validation that must throw
/// before hitting the network.
final class ErrorPathTests: XCTestCase {
    private var wireMock: WireMock!
    private let randomID = UUID()

    override func setUp() async throws {
        wireMock = try await WireMockFixture.clientOrSkip()
    }

    override func tearDown() async throws {
        if wireMock != nil { try? await wireMock.resetAll() }
    }

    // MARK: Client-side validation (no network)

    func testRegisterRawWithInvalidJSONThrows() async throws {
        do {
            try await wireMock.register(raw: "{ this is not valid json ")
            XCTFail("register(raw:) should reject invalid JSON")
        } catch let error as WireMockError {
            guard case .decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    // MARK: Unmatched request -> 404

    func testUnmatchedRequestReturns404() async throws {
        try await wireMock.stubFor(get(urlEqualTo("/known")).willReturn(ok()))
        let (_, response) = try await WireMockFixture.hit("unknown")
        XCTAssertEqual(response.statusCode, 404, "an unstubbed path must return 404")
    }

    // MARK: Admin 404 -> unexpectedStatus

    func testGetStubMappingUnknownIDThrows404() async throws {
        do {
            _ = try await wireMock.getStubMapping(id: randomID)
            XCTFail("getStubMapping with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    func testEditStubMappingUnknownIDThrows404() async throws {
        let mapping = get(urlEqualTo("/x")).willReturn(ok()).build()
        do {
            _ = try await wireMock.editStubMapping(id: randomID, mapping)
            XCTFail("editStubMapping with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    func testGetServeEventUnknownIDThrows404() async throws {
        do {
            _ = try await wireMock.getServeEvent(id: randomID)
            XCTFail("getServeEvent with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: Admin 422 -> unexpectedStatus (unknown match operator)

    func testRegisteringUnknownMatchOperatorThrows422() async throws {
        // An unknown match operator is validated and rejected by the server with
        // HTTP 422 — the raw escape hatch lets us drive that error path. Asserts
        // the server's status and (non-empty) error body surface to the caller.
        let raw = #"""
        {
          "request": { "method": "GET", "urlPath": "/n",
            "queryParameters": { "n": { "totallyBogusOperator": "5" } } },
          "response": { "status": 200 }
        }
        """#
        do {
            try await wireMock.register(raw: raw)
            XCTFail("registering an unknown match operator should be rejected with 422")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 422)
            XCTAssertFalse(body.isEmpty, "the server's error body should be surfaced")
        }
    }
}
