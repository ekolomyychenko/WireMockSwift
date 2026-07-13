// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WireMockSwift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
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
            dependencies: ["WireMock"]
        ),
    ]
)
