// swift-tools-version: 6.0
import PackageDescription

// Header search path for the vendored libgit2 (see Scripts/build-libgit2.sh). Every target that
// can see StackCore's CLibGit2 import needs it, because clang builds the module per importer.
let git2Include = "-I" + Context.packageDirectory + "/Vendor/libgit2/include"

let package = Package(
    name: "Kokoro",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StackCore", targets: ["StackCore"]),
        .library(name: "StackMCP", targets: ["StackMCP"]),
        .library(name: "StackHTTP", targets: ["StackHTTP"]),
        .executable(name: "kokoro-mcp", targets: ["KokoroMCP"]),
        .library(name: "KokoroCore", targets: ["KokoroCore"]),
        .executable(name: "Kokoro", targets: ["Kokoro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.17"),
        // Auxiliary (non-Bonsai) models: embeddings via MLXEmbedders. See docs/plans/m0-status.md item 4.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        // HTTP server for the opt-in OpenAI-compatible API (decision 6 in docs/plans/2026-09-28-next-phase-plan.md).
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
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

        // libgit2, built statically into Vendor/libgit2 by Scripts/build-libgit2.sh (no Homebrew needed).
        .systemLibrary(
            name: "CLibGit2",
            path: "Modules/CLibGit2"
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
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/StackCore",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", Context.packageDirectory + "/Vendor/libgit2/lib"]),
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
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        // HTTP adapter: OpenAI-compatible API on loopback. Translation types have no HTTP dependency.
        .target(
            name: "StackHTTP",
            dependencies: [
                "StackCore",
                "StackMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/StackHTTP",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        // App logic: state reducer, service wiring, prompt engineering. Re-exports the stack
        // so UI and tests can keep a single `import KokoroCore`.
        .target(
            name: "KokoroCore",
            dependencies: ["StackCore", "StackMCP", "StackHTTP"],
            path: "Sources/Kokoro",
            exclude: [
                "UI/",
                "App/KokoroApp.swift",
                "Info.plist",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        .executableTarget(
            name: "Kokoro",
            dependencies: ["KokoroCore"],
            path: "Sources/Kokoro",
            exclude: [
                "Info.plist",
                "App/APISharingModel.swift",
                "App/AppAppearance.swift",
                "App/AppBrand.swift",
                "App/AppCoordinator.swift",
                "App/AppServices.swift",
                "App/ApprovalCenter.swift",
                "App/BriefContextSource.swift",
                "App/BriefFeedbackModel.swift",
                "App/BriefImproveModel.swift",
                "App/BriefSidecarModel.swift",
                "App/BriefWorkbenchModel.swift",
                "App/CloudUsageModel.swift",
                "App/ConnectSnippets.swift",
                "App/DefaultsKey.swift",
                "App/DiagnosticsCollector.swift",
                "App/DiagnosticsModel.swift",
                "App/LoginItem.swift",
                "App/MenuBarStatus.swift",
                "App/ModelListing.swift",
                "App/NavDestination.swift",
                "App/PromptStudioModel.swift",
                "App/QuitPolicy.swift",
                "App/RevealPacer.swift",
                "App/RoutingPolicyLabels.swift",
                "App/SetupModel.swift",
                "App/StackExports.swift",
                "App/UpdateChecker.swift",
                "App/UpdatesModel.swift",
                "App/WorkspacesModel.swift",
            ],
            sources: [
                "App/KokoroApp.swift",
                "UI/",
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        // Performance harness for the local model (see docs/plans/2026-09-28-next-phase-plan.md, M0).
        .executableTarget(
            name: "KokoroBench",
            dependencies: [
                "StackCore",
                "StackHTTP",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/KokoroBench",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        // stdio ↔ MCP socket bridge for clients that only speak stdio.
        .executableTarget(
            name: "KokoroMCP",
            path: "Sources/KokoroMCP"
        ),

        // Embedding-model bake-off (retrieval quality/speed on this repo's own code).
        .executableTarget(
            name: "KokoroEmbedBench",
            dependencies: [
                "StackCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/KokoroEmbedBench",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-Xcc", git2Include]),
            ]
        ),

        .testTarget(
            name: "KokoroTests",
            dependencies: [
                "KokoroCore", "StackCore", "StackMCP", "StackHTTP",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/KokoroTests",
            swiftSettings: [.unsafeFlags(["-Xcc", git2Include])]
        ),
    ]
)
