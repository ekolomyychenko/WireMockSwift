// Compiled example: building stubs with the DSL. SwiftPM builds every file under
// Snippets/ as part of `swift build`, so these README-style samples can never rot
// into non-compiling code. They construct DSL values only (no network), so the
// snippet is safe to run as well as compile.
import Foundation
import WireMock

// A simple GET stub returning a JSON body.
let helloStub = get(urlEqualTo("/hello"))
    .willReturn(okForJson(["message": "world"]))
    .build()

// A POST stub with header + body matchers, a scenario, and a templated response.
let createStub = post(urlPathEqualTo("/things"))
    .withHeader("Content-Type", equalTo("application/json"))
    .withRequestBody(matchingJsonPath("$.name"))
    .inScenario("crud").whenScenarioStateIs("Started").willSetStateTo("created")
    .atPriority(1)
    .willReturn(
        created()
            .withHeader("Location", "/things/1")
            .withResponseTemplating()
            .withBody(#"{"id":"{{randomValue type='UUID'}}"}"#)
    )
    .build()

// Bulk matchers + a GET-or-HEAD stub (WireMock's GET_OR_HEAD).
let searchStub = getOrHead(urlPathEqualTo("/search"))
    .withHeaders(["Accept": equalTo("application/json")])
    .withQueryParams(["q": matching(".+"), "page": equalTo("1")])
    .willReturn(ok("[]"))
    .build()

// Encode any mapping to the exact admin JSON the server accepts.
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
for stub in [helloStub, createStub, searchStub] {
    print(String(decoding: try encoder.encode(stub), as: UTF8.self))
}
