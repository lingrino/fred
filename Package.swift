// swift-tools-version: 6.4
import PackageDescription

// Hot-path modules are compiled with bounds/overflow checks and exclusivity checking
// disabled in release builds. Correctness is enforced by tests (debug builds keep all
// checks) — see CLAUDE.md "Safety model".
let releaseFast: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-wmo"], .when(configuration: .release)),
]

let package = Package(
    name: "fred",
    platforms: [.macOS("26.0")],
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
            swiftSettings: releaseFast,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Contacts"),
            ]
        ),
        .executableTarget(name: "FredBench", dependencies: ["FredCore"], swiftSettings: releaseFast),
        .testTarget(name: "FredCoreTests", dependencies: ["FredCore"]),
    ]
)
