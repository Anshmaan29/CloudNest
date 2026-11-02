// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudNest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudNestCore", targets: ["CloudNestCore"]),
        .executable(name: "CloudNest", targets: ["CloudNest"]),
        .executable(name: "cloudnest-cli", targets: ["CloudNestCLI"]),
        .executable(name: "cloudnest-bench", targets: ["CloudNestBench"]),
        .executable(name: "CloudNestUpdateHelper", targets: ["CloudNestUpdateHelper"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "CSQLite"),
        .target(name: "CloudNestCore", dependencies: ["CSQLite"], path: ".",
                exclude: ["CloudNest", "CLI", "Bench", "Tests", "CSQLite", "UpdateHelper", "Package.swift"],
                sources: ["Core", "Storage", "Database"]),
        .executableTarget(name: "CloudNest", dependencies: ["CloudNestCore"], path: "CloudNest"),
        .executableTarget(name: "CloudNestCLI", dependencies: ["CloudNestCore"], path: "CLI"),
        .executableTarget(name: "CloudNestBench", dependencies: ["CloudNestCore"], path: "Bench"),
        .executableTarget(name: "CloudNestUpdateHelper", dependencies: ["CloudNestCore"], path: "UpdateHelper"),
        .testTarget(name: "CloudNestTests", dependencies: ["CloudNestCore"], path: "Tests")
    ]
)
