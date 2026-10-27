// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntenneCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AntenneCore", targets: ["AntenneCore"]),
    ],
    targets: [
        .target(name: "AntenneCore"),
        .testTarget(name: "AntenneCoreTests", dependencies: ["AntenneCore"]),
    ]
)
