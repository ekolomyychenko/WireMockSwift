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

    override func setUpWithError() throws {
        wireMock = try WireMockFixture.clientOrSkip()
    }

    override func tearDownWithError() throws {
        if wireMock != nil { try? wireMock.resetAll() }
    }

    // MARK: Client-side validation (no network)

    func testRegisterRawWithInvalidJSONThrows() throws {
        do {
            try wireMock.register(raw: "{ this is not valid json ")
            XCTFail("register(raw:) should reject invalid JSON")
        } catch let error as WireMockError {
            guard case .decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    // MARK: Unmatched request -> 404

    func testUnmatchedRequestReturns404() throws {
        try wireMock.stubFor(get(urlEqualTo("/known")).willReturn(ok("served")))
        // Positive control: the stub actually serves, so the 404 below is proven
        // to come from non-matching, not a dead stub or a broken server.
        let matched = try WireMockFixture.hit("known")
        WireMockFixture.assertMatch(matched)
        XCTAssertEqual(String(data: matched.0, encoding: .utf8), "served")
        WireMockFixture.assertMiss(try WireMockFixture.hit("unknown"), "an unstubbed path must return 404")
    }

    // MARK: Admin 404 -> unexpectedStatus

    func testGetStubMappingUnknownIDThrows404() throws {
        do {
            _ = try wireMock.getStubMapping(id: randomID)
            XCTFail("getStubMapping with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    func testEditStubMappingUnknownIDThrows404() throws {
        let mapping = get(urlEqualTo("/x")).willReturn(ok()).build()
        do {
            _ = try wireMock.editStubMapping(id: randomID, mapping)
            XCTFail("editStubMapping with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    func testGetServeEventUnknownIDThrows404() throws {
        do {
            _ = try wireMock.getServeEvent(id: randomID)
            XCTFail("getServeEvent with an unknown id should throw")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, _) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: Admin 422 -> unexpectedStatus (unknown match operator)

    func testRegisteringUnknownMatchOperatorThrows422() throws {
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
            try wireMock.register(raw: raw)
            XCTFail("registering an unknown match operator should be rejected with 422")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 422)
            // Prove it's the operator-validation error that surfaced, not just
            // some non-empty payload. (Version-tolerant: not pinning exact JSON.)
            XCTAssertTrue(body.contains("not a valid match operation"),
                          "the operator-rejection message should surface to the caller: \(body)")
        }
    }
}
