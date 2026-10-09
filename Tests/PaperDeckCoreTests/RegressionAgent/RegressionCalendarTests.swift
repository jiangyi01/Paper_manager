import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 5: Engine.Dependencies.calendar defaulted to `Calendar.current`, a snapshot — after the
/// Mac changed time zone (travel) the engine kept computing "today" in the old zone.
/// (Checked by identity rather than by mutating NSTimeZone.default, which would race other suites.)
@Suite struct RegressionCalendarTests {
    /// Ported (identity form).
    @Test func engineCalendarIsASnapshot() {
        let deps = Engine.Dependencies(fetcher: nil)
        #expect(deps.calendar == Calendar.autoupdatingCurrent, "engine calendar is a snapshot of the launch time zone")
        #expect(deps.calendar != Calendar.current)
        #expect(String(describing: deps.calendar).contains("autoupdating"))
    }

    @Test func engineContextDefaultCalendarFollowsTheSystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-ra-cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths.rooted(at: root)
        let ctx = EngineContext(paths: paths, db: try Database.inMemory(), sidecars: SidecarWriter(paths: paths),
                                texts: TextStore(paths: paths), thumbs: ThumbnailStore(paths: paths),
                                events: EventHub<EngineEvent>(), loadSettings: { EngineSettings() })
        #expect(ctx.calendar == Calendar.autoupdatingCurrent)
    }
}
