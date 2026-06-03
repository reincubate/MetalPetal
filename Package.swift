// swift-tools-version:5.9

// requires SE-0271

import PackageDescription

let package = Package(
    name: "MetalPetal",
    platforms: [.macOS(.v10_13), .iOS(.v11), .tvOS(.v13), .visionOS(.v1)],
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
            dependencies: ["MetalPetalObjectiveC"]),
        .target(
            name: "MetalPetalObjectiveC",
            dependencies: [],
            // MetalFX (used by MTIFXSpatialScalerKernel) is only available on macOS 13 /
            // iOS 16+. Weak-link it so binaries still launch on older OS versions, where the
            // kernel is gated behind +isSupportedByDevice: / @available and never invoked.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "MetalFX"])
            ]),
    ],
    cxxLanguageStandard: .cxx14
)
