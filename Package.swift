// swift-tools-version:6.0

// requires SE-0271

import PackageDescription

let package = Package(
    name: "MetalPetal",
    platforms: [.macOS(.v10_13), .iOS(.v12), .tvOS(.v13), .visionOS(.v1)],
    products: [
        .library(
            name: "MetalPetal",
            targets: ["MetalPetal"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MetalPetal",
            dependencies: ["MetalPetalObjectiveC"]
        ),
        .target(
            name: "MetalPetalObjectiveC",
            dependencies: []),
    ],
    cxxLanguageStandard: .cxx14
)
