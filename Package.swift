// swift-tools-version:6.2
import PackageDescription

// PaperDeck — macOS paper-reading manager. Built with Command Line Tools only
// (no Xcode): `./build_app.sh` assembles and signs the .app, `./test.sh` runs tests.
let appExtensionSafe: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "PaperDeck",
    platforms: [.macOS(.v26)],
    targets: [
        // Foundation-only code shared by the app and the widget extension.
        .target(name: "PaperDeckShared", swiftSettings: appExtensionSafe),
        // Objective-C shims Swift can't express: catching an exception a framework throws
        // (PDFKit's "nil NSFont" under concurrency, R-PDFKIT-2). Nothing else.
        .target(name: "PaperDeckObjCSupport"),
        // Window-free engine: models, SQLite, import pipeline, planner, agent runner.
        .target(
            name: "PaperDeckCore",
            dependencies: ["PaperDeckShared", "PaperDeckObjCSupport"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Presets and configuration (institution, research field, mail sources, settings transfer,
        // guide model + content): values only, no UI, no actors. Core can't import it, so the
        // engine can never branch on an institution; tests can, so the presets are unit-testable.
        .target(
            name: "PaperDeckConfig",
            dependencies: ["PaperDeckCore", "PaperDeckShared"]
        ),
        // AppKit + SwiftUI shell (also hosts the headless CLI: --selftest, --doctor…).
        .executableTarget(
            name: "PaperDeck",
            dependencies: ["PaperDeckCore", "PaperDeckShared", "PaperDeckConfig"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // WidgetKit extension (display-only). ExtensionKit entry point + a Swift main
        // that calls WidgetBundle.main(); build_app.sh verifies both survive linking.
        .executableTarget(
            name: "PaperDeckWidget",
            dependencies: ["PaperDeckShared"],
            swiftSettings: appExtensionSafe,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-u", "-Xlinker", "_main"])]
        ),
        .testTarget(
            name: "PaperDeckCoreTests",
            dependencies: ["PaperDeckCore", "PaperDeckShared", "PaperDeckConfig"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
