// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InstantCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "InstantCore", targets: ["InstantCore"]),
        .executable(name: "instant-lab", targets: ["instant-lab"]),
    ],
    targets: [
        .target(name: "InstantCore"),
        .executableTarget(name: "instant-lab", dependencies: ["InstantCore"]),
    ]
)
