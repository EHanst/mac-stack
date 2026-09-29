// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCockpit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StackCore", targets: ["StackCore"]),
        .library(name: "StackMCP", targets: ["StackMCP"]),
        .library(name: "VibeCockpitCore", targets: ["VibeCockpitCore"]),
        .executable(name: "VibeCockpit", targets: ["VibeCockpit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.17"),
        // Auxiliary (non-Bonsai) models: embeddings via MLXEmbedders. See docs/plans/m0-status.md item 4.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
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

        // Engine: inference, routing, scheduling, storage, indexing, git, execution. No MCP, no UI.
        .target(
            name: "StackCore",
            dependencies: [
                "CSQLiteVec",
                "CLibGit2",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/StackCore",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        // MCP adapter: exposes StackCore's tools over the Model Context Protocol.
        .target(
            name: "StackMCP",
            dependencies: [
                "StackCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/StackMCP",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        // App logic: state reducer, service wiring, prompt engineering. Re-exports the stack
        // so UI and tests can keep a single `import VibeCockpitCore`.
        .target(
            name: "VibeCockpitCore",
            dependencies: ["StackCore", "StackMCP"],
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

        .executableTarget(
            name: "VibeCockpit",
            dependencies: ["VibeCockpitCore"],
            path: "Sources/VibeCockpit",
            sources: [
                "App/VibeCockpitApp.swift",
                "UI/",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        // Performance harness for the local model (see docs/plans/2026-09-28-next-phase-plan.md, M0).
        .executableTarget(
            name: "VibeBench",
            dependencies: [
                "StackCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/VibeBench",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        // Embedding-model bake-off (retrieval quality/speed on this repo's own code).
        .executableTarget(
            name: "VibeEmbedBench",
            dependencies: [
                "StackCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/VibeEmbedBench",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),

        .testTarget(
            name: "VibeCockpitTests",
            dependencies: ["VibeCockpitCore", "StackCore", "StackMCP"],
            path: "Tests/VibeCockpitTests"
        ),
    ]
)
