// swift-tools-version: 6.2
// Jeeves: shared library modules, M0 spike executables, and tests.
// The menu bar app lives in App/ (generated with XcodeGen) and depends on this package.
import PackageDescription

let sqliteDefines: [CSetting] = [
    .define("SQLITE_CORE"),                 // sqlite-vec compiled into SQLite, not loaded
    .define("SQLITE_VEC_STATIC"),
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_DQS", to: "0"),
    .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
    .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
    .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
    .define("SQLITE_OMIT_SHARED_CACHE"),
    .define("SQLITE_USE_ALLOCA"),
    .define("SQLITE_VEC_ENABLE_NEON", .when(platforms: [.macOS])),  // Apple silicon only
    // SQLite defines MIN/MAX, which clash harmlessly with <sys/param.h> under clang
    // modules on macOS (62 warnings). Allowed because the app uses this package locally.
    .unsafeFlags(["-Wno-ambiguous-macro"], .when(platforms: [.macOS])),
]

let package = Package(
    name: "Jeeves",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JeevesKit", targets: ["JeevesCore", "AnthropicAPI", "KnowledgeIndex", "Assistant", "AudioCapture", "Transcription"]),
        .executable(name: "spike-claude", targets: ["SpikeClaude"]),
        .executable(name: "spike-vec", targets: ["SpikeVec"]),
        .executable(name: "spike-tap", targets: ["SpikeTap"]),
        .executable(name: "spike-stt", targets: ["SpikeSTT"]),
        .executable(name: "spike-capture", targets: ["SpikeCapture"]),
        .executable(name: "spike-asr", targets: ["SpikeASR"]),
        .executable(name: "spike-kb", targets: ["SpikeKB"]),
        .executable(name: "spike-qa", targets: ["SpikeQA"]),
    ],
    dependencies: [
        // Parakeet speech recognition on Apple silicon (M2 engine comparison). Pinned;
        // `traits: []` builds speech recognition and VAD only, without TTS, diarization
        // or the prebuilt text-normalization binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
    ],
    targets: [
        // Vendored SQLite amalgamation + sqlite-vec (see Sources/CSQLite/VENDORED.md).
        .target(
            name: "CSQLite",
            exclude: ["VENDORED.md", "LICENSE-sqlite-vec-MIT", "LICENSE-sqlite-vec-APACHE"],
            cSettings: sqliteDefines,
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
            ]
        ),

        // Cross-platform modules (build and test on Linux and macOS).
        .target(name: "JeevesCore"),
        .target(name: "AnthropicAPI", dependencies: ["JeevesCore"]),
        .target(name: "KnowledgeIndex", dependencies: ["CSQLite", "JeevesCore"]),
        // Question -> passages -> streamed answer (M4), shared by the app and spike-kb.
        .target(name: "Assistant", dependencies: ["KnowledgeIndex", "AnthropicAPI", "JeevesCore"]),

        // macOS-only modules. Sources are wrapped in `#if os(macOS)` so the package
        // still builds (as empty modules) on Linux CI.
        .target(name: "AudioCapture", dependencies: ["JeevesCore"]),
        .target(name: "Transcription", dependencies: [
            "JeevesCore", "AudioCapture",
            .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS])),
        ]),

        // M0 spikes. Each prints measurements to paste into docs/M0.md.
        .executableTarget(name: "SpikeClaude", dependencies: ["AnthropicAPI", "JeevesCore"]),
        .executableTarget(name: "SpikeVec", dependencies: ["KnowledgeIndex", "JeevesCore"]),
        .executableTarget(name: "SpikeTap", dependencies: ["AudioCapture", "JeevesCore"]),
        .executableTarget(name: "SpikeSTT", dependencies: ["Transcription", "AudioCapture", "JeevesCore"]),
        .executableTarget(name: "SpikeCapture", dependencies: ["AudioCapture", "JeevesCore"]),
        .executableTarget(name: "SpikeASR", dependencies: ["Transcription", "AudioCapture", "JeevesCore"]),
        .executableTarget(name: "SpikeKB", dependencies: ["Assistant", "KnowledgeIndex", "AnthropicAPI", "JeevesCore"]),
        // Question assembly calibration: replays call traces (docs/QUESTIONS.md). Cross-platform.
        .executableTarget(name: "SpikeQA", dependencies: ["JeevesCore", "AnthropicAPI"]),

        .testTarget(name: "JeevesCoreTests", dependencies: ["JeevesCore"]),
        .testTarget(name: "AnthropicAPITests", dependencies: ["AnthropicAPI"]),
        .testTarget(name: "KnowledgeIndexTests", dependencies: ["KnowledgeIndex", "JeevesCore"]),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant", "KnowledgeIndex", "AnthropicAPI"]),
    ],
    swiftLanguageModes: [.v6]
)
