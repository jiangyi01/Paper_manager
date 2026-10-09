import Foundation
import Testing

/// The scratch domain helper keeps test preferences out of ~/Library/Preferences.
@Suite struct ScratchDefaultsTests {
    @Test func theDomainLivesInItsOwnTemporaryDirectory() {
        let scratch = ScratchDefaults("scratch-self-test")
        defer { scratch.drop() }
        let preferences = URL.libraryDirectory.appending(path: "Preferences").standardizedFileURL.path
        #expect(scratch.name.hasPrefix("/") && !scratch.name.hasPrefix(preferences))
        #expect(scratch.directory.deletingLastPathComponent().standardizedFileURL == ScratchDefaults.parent.standardizedFileURL)
        #expect(ScratchDefaults.parent.lastPathComponent.hasPrefix(ScratchDefaults.prefix))
        #expect(scratch.plistURL.deletingLastPathComponent().standardizedFileURL == scratch.directory.standardizedFileURL)

        scratch.defaults.set("x", forKey: "k")
        scratch.defaults.set(["a": 1], forKey: "d")
        #expect(scratch.defaults.string(forKey: "k") == "x")
        // Another instance on the same name sees the same domain (as the app's SettingsStore would).
        #expect(UserDefaults(suiteName: scratch.name)?.dictionary(forKey: "d") as? [String: Int] == ["a": 1])
        scratch.defaults.removeObject(forKey: "k")
        #expect(scratch.defaults.object(forKey: "k") == nil)
    }

    @Test func dropRemovesTheDomainAndItsDirectory() {
        let scratch = ScratchDefaults("scratch-self-test")
        scratch.defaults.set("x", forKey: "k")
        scratch.drop()
        #expect(!FileManager.default.fileExists(atPath: scratch.directory.path))
        #expect(UserDefaults(suiteName: scratch.name)?.object(forKey: "k") == nil)
    }

    @Test func namesAreUniquePerInstance() {
        let a = ScratchDefaults("same"), b = ScratchDefaults("same")
        defer { a.drop(); b.drop() }
        #expect(a.name != b.name)
    }
}
