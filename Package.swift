// swift-tools-version: 6.2
import PackageDescription

// Recast: drag-and-drop batch audio converter (WAV, AIFF, CAF, FLAC, Apple Lossless, MP3, AAC, Ogg Vorbis, Opus).
let package = Package(
    name: "Recast",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates (release builds only; see build.sh). Pinned: bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // LAME 3.100 MP3 encoder (LGPL), vendored unmodified and built as its own dynamic library (libmp3lame.dylib)
        // so it stays separate and replaceable, as the LGPL asks. See Packages/Lame.
        .package(path: "Packages/Lame"),
    ],
    targets: [
        // libogg + libvorbis 1.3.7 (BSD), as bundled with JUCE.
        .target(
            name: "COggVorbis",
            path: "Sources/COggVorbis",
            sources: ["oggvorbis_unity.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("JUCE_CDECL", to: ""),
                // Upstream headers rely on <sys/types.h> providing uint64_t, which Clang modules hide.
                .unsafeFlags(["-w", "-include", "stdint.h"]),
            ]
        ),
        .target(
            name: "RecastCore",
            dependencies: [.product(name: "mp3lame", package: "Lame"), "COggVorbis"],
            path: "Sources/RecastCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Recast",
            dependencies: ["RecastCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Recast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecastCoreTests",
            dependencies: ["RecastCore"],
            path: "Tests/RecastCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
