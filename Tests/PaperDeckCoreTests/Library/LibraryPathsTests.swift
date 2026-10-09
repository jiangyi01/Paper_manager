import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct LibraryPathsTests {
    private static func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func cleanup(_ root: URL) {
        chmod(root.path, 0o755)
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e { chmod(root.appendingPathComponent(rel).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func statusOfHealthyMissingAndReadOnlyRoots() throws {
        let root = try Self.tempRoot()
        defer { Self.cleanup(root) }
        #expect(LibraryPaths.status(of: root) == .ok)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)      // probe cleaned up

        #expect(LibraryPaths.status(of: root.appendingPathComponent("absent")) == .missing)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(LibraryPaths.status(of: file) == .missing)

        let ro = root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: false)
        #expect(chmod(ro.path, 0o555) == 0)
        #expect(LibraryPaths.status(of: ro) == .readOnly)
        #expect(!LibraryPaths.status(of: ro).isUsable)

        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        #expect(chmod(locked.path, 0o000) == 0)
        #expect(LibraryPaths.status(of: locked) == .denied)
        #expect(LibraryPaths.status(of: locked.appendingPathComponent("inner")) == .denied)
    }

    @Test func ensureLayoutCreatesEverythingIdempotently() throws {
        let root = try Self.tempRoot()
        defer { Self.cleanup(root) }
        let paths = AppPaths.rooted(at: root)
        try LibraryPaths.ensureLayout(paths: paths)
        try LibraryPaths.ensureLayout(paths: paths)

        let expected = [paths.library, paths.papers, paths.inbox, paths.partial, paths.recentlyDeleted,
                        paths.support, paths.textCache, paths.agentCwd, paths.jobs, paths.backups,
                        paths.widget, paths.widgetThumbs, paths.caches, paths.thumbnails, paths.incoming]
        for dir in expected {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue, "\(dir.path)")
        }
        for dir in [paths.caches, paths.thumbnails, paths.incoming] {
            var u = dir
            u.removeAllCachedResourceValues()
            #expect(try u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        var lib = paths.library
        lib.removeAllCachedResourceValues()
        #expect(try lib.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
        #expect(LibraryPaths.status(of: paths.library) == .ok)
    }

    @Test func ensureLayoutNeverRecreatesAVanishedLibraryParent() throws {
        let root = try Self.tempRoot()
        defer { Self.cleanup(root) }
        let paths = AppPaths(library: root.appendingPathComponent("Volumes/Gone/PaperDeck"),
                             support: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"),
                             widget: root.appendingPathComponent("Support/widget"))
        #expect(throws: FileOpsError.libraryUnavailable) { try LibraryPaths.ensureLayout(paths: paths) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Volumes").path))

        let ro = root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: false)
        #expect(chmod(ro.path, 0o555) == 0)
        let roPaths = AppPaths(library: ro.appendingPathComponent("PaperDeck"), support: paths.support,
                               caches: paths.caches, widget: paths.widget)
        #expect(throws: FileOpsError.permissionDenied) { try LibraryPaths.ensureLayout(paths: roPaths) }
    }

    @Test func relativePaths() {
        let lib = URL(fileURLWithPath: "/tmp/pd/Library", isDirectory: true)
        let folder = LibraryPaths.folderURL(forRelative: "Papers/2024_Wang_X", library: lib)
        #expect(folder.path == "/tmp/pd/Library/Papers/2024_Wang_X")
        #expect(LibraryPaths.relativePath(of: folder, root: lib) == "Papers/2024_Wang_X")
        #expect(LibraryPaths.relativePath(of: URL(fileURLWithPath: "/private/tmp/pd/Library/Papers/A"), root: lib) == "Papers/A")
        #expect(LibraryPaths.relativePath(of: URL(fileURLWithPath: "/tmp/pd/Other/A"), root: lib) == nil)
        #expect(LibraryPaths.relativePath(of: lib, root: lib) == nil)
    }
}
