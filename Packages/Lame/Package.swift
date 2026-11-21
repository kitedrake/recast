// swift-tools-version: 6.2
import PackageDescription

// LAME 3.100's MP3 encoder (GNU LGPL v2), vendored unmodified in Sources/CLame and built as its own dynamic library,
// libmp3lame.dylib. Recast links it at run time from Recast.app/Contents/Frameworks, so it stays a separate,
// replaceable library, as the LGPL asks. Only the encoder is built (no decoder, assembly or front end).
let package = Package(
    name: "Lame",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "mp3lame", type: .dynamic, targets: ["CLame"]),
    ],
    targets: [
        .target(
            name: "CLame",
            path: "Sources/CLame",
            exclude: ["COPYING", "LICENSE", "README", "OMSO_PROVENANCE.md", "config"],
            sources: ["libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("config"),
                .headerSearchPath("libmp3lame"),
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
