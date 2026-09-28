// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCockpit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VibeCockpitCore", targets: ["VibeCockpitCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // mlx-swift and swift-transformers are excluded until their transitive dependencies
        // (swift-argument-parser ≤ 1.8.2, CudaBuild plugin) are fixed for macOS 26 SDK 27.
        // LocalMLXProvider.swift stubs the ModelProvider protocol until then.
        // To re-enable: add back the two packages below and uncomment in VibeCockpitCore deps.
        // .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0"),
        // .package(url: "https://github.com/huggingface/swift-transformers.git", "0.1.13"..<"0.1.14"),
    ],
    targets: [
        // C module: sqlite-vec (compiled amalgamation)
        .target(
            name: "CSQLiteVec",
            path: "Modules/CSQLiteVec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_ENABLE_FTS5"),
            ]
        ),

        // C system library: libgit2 (Homebrew-installed)
        .systemLibrary(
            name: "CLibGit2",
            path: "Modules/CLibGit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),

        .target(
            name: "VibeCockpitCore",
            dependencies: [
                "CSQLiteVec",
                "CLibGit2",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Crypto", package: "swift-crypto"),
                // .product(name: "MLX", package: "mlx-swift"),
                // .product(name: "MLXNN", package: "mlx-swift"),
                // .product(name: "MLXRandom", package: "mlx-swift"),
                // .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/VibeCockpit",
            exclude: [
                "UI/",
                "App/VibeCockpitApp.swift",
                "Info.plist",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        .testTarget(
            name: "VibeCockpitTests",
            dependencies: ["VibeCockpitCore"],
            path: "Tests/VibeCockpitTests"
        ),
    ]
)
