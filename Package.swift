// swift-tools-version: 6.4
import PackageDescription

// FredCore — the search/learning/storage kernels — is compiled with bounds/overflow checks
// and exclusivity checking disabled in release builds; its correctness is enforced by unit
// and fuzz tests (debug builds keep all checks). The app target keeps Swift's normal
// release checks: its code isn't hot, and a bug there should crash loudly, not silently
// corrupt memory (lesson from the 2026-11-14 review).
let releaseFast: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
]

let package = Package(
    name: "fred",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Fred", targets: ["Fred"]),
        .executable(name: "fredbench", targets: ["FredBench"]),
    ],
    targets: [
        // Pure logic: index, matching, ranking, learning, calculator, storage formats.
        // No AppKit. Everything here is unit-tested and benchmarked.
        .target(name: "FredCore", swiftSettings: releaseFast),
        // The app: AppKit UI, hotkeys, platform integrations (apps, contacts, clipboard...).
        .executableTarget(
            name: "Fred",
            dependencies: ["FredCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Contacts"),
            ]
        ),
        .executableTarget(name: "FredBench", dependencies: ["FredCore"]),
        .testTarget(name: "FredCoreTests", dependencies: ["FredCore"]),
    ]
)
