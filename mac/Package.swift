// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudNest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudNestCore", targets: ["CloudNestCore"]),
        .executable(name: "CloudNest", targets: ["CloudNest"]),
        .executable(name: "cloudnest-cli", targets: ["CloudNestCLI"]),
        .executable(name: "cloudnest-bench", targets: ["CloudNestBench"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "CSQLite"),
        .target(name: "CloudNestCore", dependencies: ["CSQLite"], path: ".",
                exclude: ["CloudNest", "CLI", "Bench", "Tests", "CSQLite", "Package.swift"],
                sources: ["Core", "Storage", "Database"]),
        .executableTarget(name: "CloudNest", dependencies: ["CloudNestCore"], path: "CloudNest"),
        .executableTarget(name: "CloudNestCLI", dependencies: ["CloudNestCore"], path: "CLI"),
        .executableTarget(name: "CloudNestBench", dependencies: ["CloudNestCore"], path: "Bench"),
        .testTarget(name: "CloudNestTests", dependencies: ["CloudNestCore"], path: "Tests")
    ]
)
