// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WireMockSwift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "WireMock", targets: ["WireMock"]),
    ],
    targets: [
        .target(
            name: "WireMock"
        ),
        .testTarget(
            name: "WireMockTests",
            dependencies: ["WireMock"],
            // Real server responses captured by Scripts/capture-fixtures.sh, loaded
            // via Bundle.module by RecordedContractTests to pin the decode contract.
            resources: [.copy("Fixtures")]
        ),
    ]
)
