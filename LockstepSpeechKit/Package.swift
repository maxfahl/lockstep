// swift-tools-version: 6.2

import PackageDescription

// Speech to text for Lockstep: whisper.cpp, run on this Mac, with a model that
// `Scripts/install-speech-model.sh` downloads.
//
// This is a package of its own, not a target of LockstepKit, so that LockstepKit's tests never
// fetch whisper.cpp or link it. Only the Lockstep app does.
//
// whisper.cpp comes as the XCFramework its project publishes with each build. b5454 is the build
// of v1.9.5's commit (d1be6fde11ac6e0407606b4e42fe72d34add8037). The checksum is the SHA-256 of
// the zip, which SwiftPM checks before it uses it.
let package = Package(
    name: "LockstepSpeechKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LockstepSpeech", targets: ["LockstepSpeech"])
    ],
    dependencies: [
        .package(path: "../LockstepKit")
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(
            name: "LockstepSpeech",
            dependencies: [
                .product(name: "LockstepCore", package: "LockstepKit"),
                "whisper",
            ]
        ),
        .testTarget(name: "LockstepSpeechTests", dependencies: ["LockstepSpeech"]),
    ],
    swiftLanguageModes: [.v6]
)
