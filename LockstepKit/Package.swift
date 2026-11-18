// swift-tools-version: 6.2

// Part of Lockstep. Free software under the GNU General Public License, version 3 or later:
// see LICENSE and THIRD-PARTY-NOTICES.md at the top of the repository.

import PackageDescription

let package = Package(
    name: "LockstepKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LockstepCore", targets: ["LockstepCore"]),
        .library(name: "LockstepAudio", targets: ["LockstepAudio"]),
        .library(name: "LockstepUI", targets: ["LockstepUI"]),
    ],
    targets: [
        .target(name: "LockstepCore"),
        // Rubber Band, copied in unchanged under `vendor`. The one file of the target's own takes in the
        // whole library, so `vendor` is left out of the target's files. Like any stretcher it is many times
        // slower when it is not optimised, so it is optimised in debug builds too, and the warnings of code
        // that is not ours are not shown.
        .target(
            name: "CRubberBand",
            exclude: ["vendor"],
            cxxSettings: [
                .unsafeFlags(["-O2", "-w"])
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(name: "LockstepAudio", dependencies: ["LockstepCore", "CRubberBand"]),
        .target(name: "LockstepUI", dependencies: ["LockstepCore"]),
        // The tests read their fixture files straight from the source folder, so the fixtures are
        // not built into the test bundle.
        .testTarget(name: "LockstepCoreTests", dependencies: ["LockstepCore"], exclude: ["Fixtures"]),
        .testTarget(
            name: "LockstepAudioTests",
            dependencies: ["LockstepAudio", "LockstepCore"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
