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

    // MARK: Admin 422 -> unexpectedStatus (4.x-only matcher on 3.x)

    func testRegisteringUnsupportedNumericMatcherThrows422() async throws {
        // equalToNumber is WireMock 4.x-only; 3.13.2 rejects it with 422.
        let stub = get(urlPathEqualTo("/n"))
            .withQueryParam("n", .equalToNumber(5))
            .willReturn(ok()).build()
        do {
            _ = try await wireMock.register(stub)
            XCTFail("registering a 4.x-only numeric matcher should be rejected by 3.x")
        } catch let error as WireMockError {
            guard case .unexpectedStatus(let code, let body) = error else {
                return XCTFail("expected .unexpectedStatus, got \(error)")
            }
            XCTAssertEqual(code, 422)
            XCTAssertFalse(body.isEmpty, "the server's error body should be surfaced")
        }
    }
}
