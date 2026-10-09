import AppKit
import UniformTypeIdentifiers
import PaperDeckCore

/// Turns a drag pasteboard into IntakeItems. Order of preference (DESIGN §5):
/// file URLs (Finder, Preview title icon, download lists) → file promises (Mail,
/// some browsers/chat apps) → raw PDF data (Preview sidebar pages) → web links.
///
/// Once Explain ships, a drag whose every item is an image (screenshot thumbnails, PNG / JPEG /
/// TIFF / HEIC files, raw image data) goes to Explain instead of the import (LN §3 T7); a PDF, a
/// folder, an email or any other file anywhere in the drag keeps today's import exactly. The drop
/// is the gesture: Explain's ticket is minted here (`explainImages`).
enum DropIntake {
    struct Summary: Equatable {
        var pdfFiles = 0
        var folders = 0
        var otherFiles = 0
        var promises = 0
        var pdfData = false
        var links = 0
        /// Every item is an image and Explain takes it (only once Explain ships).
        var explainImages = false

        /// How many things we would try to import.
        var importable: Int { pdfFiles + folders + promises + (pdfData ? 1 : 0) + links }
        var isAcceptable: Bool { importable > 0 || explainImages }
    }

    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .pdf] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + (AssistRollout.explain ? imageDataTypes : [])
    }

    /// Cheap check used while hovering (reads URLs, never file contents).
    static func summarize(_ pb: NSPasteboard) -> Summary {
        var s = Summary()
        s.explainImages = isExplainImageDrag(pb)
        let files = fileURLs(pb)
        for url in files {
            if isFolder(url) { s.folders += 1 }
            else if isPDF(url) { s.pdfFiles += 1 }
            else { s.otherFiles += 1 }
        }
        if files.isEmpty {
            s.promises = promiseReceivers(pb).count
            if s.promises == 0 {
                s.pdfData = pb.availableType(from: [.pdf]) != nil
                if !s.pdfData { s.links = webURLs(pb).count }
            }
        }
        return s
    }

    /// Only the pasteboard *types* — safe to read for drags that belong to other apps.
    static func looksImportable(types: [NSPasteboard.PasteboardType]) -> Bool {
        let wanted = Set(registeredTypes)
        return types.contains { wanted.contains($0) }
    }

    /// Collects importable items. File promises are materialized into `incoming`
    /// asynchronously; `completion` runs on the main actor with everything found.
    static func collect(_ pb: NSPasteboard, incoming: URL,
                        completion: @escaping @MainActor ([IntakeItem], _ ignoredNames: [String]) -> Void) {
        let files = fileURLs(pb)
        if !files.isEmpty {
            var items: [IntakeItem] = []
            var ignored: [String] = []
            for url in files {
                if isFolder(url) || isPDF(url) { items.append(.file(url)) } else { ignored.append(url.lastPathComponent) }
            }
            completion(items, ignored)
            return
        }
        let receivers = promiseReceivers(pb)
        if !receivers.isEmpty {
            let dir = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            PromiseReceiving.receive(receivers, into: dir) { urls in
                MainActor.assumeIsolated {
                    let pdfs = urls.filter { isPDF($0) || FileOps.checkPDFQuietly($0) }
                    let ignored = urls.filter { !pdfs.contains($0) }.map(\.lastPathComponent)
                    completion(pdfs.map { .promised($0) }, ignored)
                }
            }
            return
        }
        if let data = pb.data(forType: .pdf), data.count > 0 {
            completion([.pdfData(data, suggestedName: "Dropped.pdf")], [])
            return
        }
        completion(webURLs(pb).map { .remote($0) }, [])
    }

    // MARK: Pasteboard readers

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func webURLs(_ pb: NSPasteboard) -> [URL] {
        let all = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        return all.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    static func promiseReceivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        // Keep promises that are (or may be) PDFs; unknown types are checked after receiving.
        return receivers.filter { r in
            r.fileTypes.isEmpty || r.fileTypes.contains { UTType($0)?.conforms(to: .pdf) ?? false }
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    static func isPDF(_ url: URL) -> Bool {
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return t.conforms(to: .pdf) }
        return url.pathExtension.lowercased() == "pdf"
    }
}

// MARK: Images → Explain

extension DropIntake {
    /// Raw image data a drag may carry (a browser image, a screenshot thumbnail).
    static var imageDataTypes: [NSPasteboard.PasteboardType] { ExplainDropRules.imageDataTypes.map { .init($0) } }

    /// The types the explanation panel itself accepts (an image dropped on it is explained).
    static var explainDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + imageDataTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// A drag Explain takes: Explain ships, and every file is an image — or, without files, every
    /// promise is an image, or the drag holds raw image data and nothing importable (no PDF).
    static func isExplainImageDrag(_ pb: NSPasteboard) -> Bool {
        guard AssistRollout.explain else { return false }
        let files = fileURLs(pb)
        if !files.isEmpty {
            return ExplainDropRules.isAllImages(files.map { isFolder($0) ? nil : contentType($0) })
        }
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty {
            return ExplainDropRules.isAllImages(receivers.flatMap { r in r.fileTypes.isEmpty ? [nil] : r.fileTypes.map { UTType($0) } })
        }
        return pb.availableType(from: [.pdf]) == nil && pb.availableType(from: imageDataTypes) != nil
    }

    /// The drop panel's and the menu-bar icon's hook: an all-image drag goes to Explain (true: taken,
    /// nothing is imported). Anything else returns false and the import runs as before.
    static func routeImageDropToExplain(_ pb: NSPasteboard, incoming: URL, near: CGRect? = nil) -> Bool {
        guard isExplainImageDrag(pb), let coordinator = ExplainBootstrap.coordinator else { return false }
        return explainImages(pb, coordinator: coordinator, near: near, incoming: incoming)
    }

    /// Explains the drag's first image (one turn takes one image). The drop is the gesture.
    @discardableResult
    static func explainImages(_ pb: NSPasteboard, coordinator: ExplainCoordinator, near: CGRect?,
                              incoming: URL = AppPaths.production().incoming) -> Bool {
        guard isExplainImageDrag(pb) else { return false }
        let ticket = ConsentTicket.mint(.drop, surface: .explain)
        let begin: @MainActor (AssistImage?) -> Void = { image in
            let capture = ExplainCapture(source: .drop, image: image)
            coordinator.begin(capture: capture, ticket: ticket, anchor: nil, kind: .explain, near: near)
        }
        let files = fileURLs(pb)
        if let url = files.first {
            begin(readImage(url))
            return true
        }
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty {
            let dir = incoming.appendingPathComponent("explain-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            PromiseReceiving.receive(Array(receivers.prefix(ExplainDropRules.maxImages)), into: dir) { urls in
                MainActor.assumeIsolated {
                    let image = urls.first.flatMap(readImage)
                    try? FileManager.default.removeItem(at: dir)          // the promised copy is ours; nothing is kept
                    begin(image)
                }
            }
            return true
        }
        for t in imageDataTypes {
            if let data = pb.data(forType: t) {
                begin(ExplainImageEncoder.encode(data: data))
                return true
            }
        }
        return false
    }

    private static func readImage(_ url: URL) -> AssistImage? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= ExplainImageEncoder.maxInputBytes, let data = try? Data(contentsOf: url) else { return nil }
        return ExplainImageEncoder.encode(data: data)
    }

    private static func contentType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? ExplainDropRules.type(ofFileNamed: url.lastPathComponent)
    }
}

private extension FileOps {
    /// Promise files sometimes arrive without an extension; sniff the header.
    static func checkPDFQuietly(_ url: URL) -> Bool { (try? checkPDF(url)) != nil }
}
