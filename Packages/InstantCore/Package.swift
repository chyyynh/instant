// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InstantCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "InstantCore", targets: ["InstantCore"]),
        .executable(name: "instant-lab", targets: ["instant-lab"]),
    ],
    dependencies: [
        // Speaker diarization (Sortformer). The NeMo text-normalization trait is for its TTS/ASR,
        // which we don't use, so leave it off and skip that prebuilt binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "InstantCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "instant-lab", dependencies: ["InstantCore", .product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
