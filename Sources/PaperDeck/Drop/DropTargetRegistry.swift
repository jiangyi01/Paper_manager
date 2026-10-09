import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore

/// Drop zones inside a window's SwiftUI content (MAIL_DESIGN Part A §3 "Per-row drop box").
///
/// `DropHostingView` overrides every dragging method (file promises need AppKit), so SwiftUI's
/// `.dropDestination` never fires inside the window. Instead, Mail rows and cards register their
/// frames here — in the named coordinate space of the inbox list, anchored by an invisible,
/// flipped AppKit view (`DropSpaceAnchor`) that converts them to window coordinates, the space
/// of `NSDraggingInfo.draggingLocation`. The hosting view hit-tests the pointer on every
/// `draggingUpdated`, the zone under it highlights (「松手作为这篇的 PDF」), and the drop goes to
/// `onTargetedDrop` instead of the generic import. Dropped emails (.eml files, email promises)
/// go to `onMailFiles` (Mail import) wherever they land.
///
/// Every inbox instance is its own *drop space* (an id in the environment): its anchor and its
/// zones live and die together, so an inbox being torn down (sidebar switch, window rebuilt)
/// never removes the zones of the one replacing it, whatever order SwiftUI does that in.
@Observable
final class DropTargetRegistry {
    static let shared = DropTargetRegistry()

    /// Named coordinate space of the Mail inbox list (rows report their frames in it).
    nonisolated static let space = "paperdeck.mail.drop-space"

    enum Target: Hashable, Sendable {
        /// One paper row: a single dropped PDF becomes this row's paper.
        case mailItem(itemID: String)
        /// A whole email card: dropped PDFs are matched to its rows by DOI / arXiv id / title.
        case mailCard(messageID: String)

        /// Rows win over the card that contains them.
        var priority: Int {
            switch self {
            case .mailItem: return 1
            case .mailCard: return 0
            }
        }

        var key: String {
            switch self {
            case .mailItem(let id): return "item:" + id
            case .mailCard(let id): return "card:" + id
            }
        }
    }

    /// One inbox list: its anchor view and its zones' local rects (anchor space, top-left origin).
    private final class Space {
        weak var anchor: NSView?
        var zones: [Target: CGRect] = [:]
    }

    /// The zone under the current drag (observed by rows and cards for their highlight).
    private(set) var hovered: Target?

    /// Written on every scroll — never observed.
    @ObservationIgnored private var spaces: [String: Space] = [:]

    /// Installed by `AppState.start()`: a drop on a registered zone.
    @ObservationIgnored var onTargetedDrop: ((Target, [IntakeItem], _ ignoredNames: [String]) -> Void)?
    /// Installed by `AppState.start()`: emails dropped anywhere (`temporary` = received promise
    /// copies under incoming/, deleted after the import).
    @ObservationIgnored var onMailFiles: (([URL], _ temporary: Bool) -> Void)?

    init() {}

    // MARK: Registration (SwiftUI side)

    func register(_ target: Target, rect: CGRect, space: String) {
        let s = spaces[space] ?? Space()
        spaces[space] = s
        if rect.isNull || rect.isEmpty { s.zones[target] = nil } else { s.zones[target] = rect }
    }

    func unregister(_ target: Target, space: String) {
        spaces[space]?.zones[target] = nil
        if hovered == target, !spaces.values.contains(where: { $0.zones[target] != nil }) { hovered = nil }
    }

    /// The flipped view that fills the inbox list (its bounds = the named space).
    func setAnchor(_ view: NSView, space: String) {
        let s = spaces[space] ?? Space()
        s.anchor = view
        spaces[space] = s
    }

    /// The inbox list went away: its space (anchor and zones) with it.
    func removeSpace(_ space: String, anchor view: NSView) {
        guard let s = spaces[space], s.anchor == nil || s.anchor === view else { return }
        spaces[space] = nil
    }

    /// Some live list has zones (cheap check before hit testing).
    var hasZones: Bool {
        spaces.values.contains { $0.anchor != nil && !$0.zones.isEmpty }
    }

    // MARK: Hit testing (AppKit side)

    /// The zone under `point` (window base coordinates of `window`) that `accepts` allows;
    /// only inside a visible list that lives in that window.
    func target(at point: CGPoint, in window: NSWindow?, accepts: (Target) -> Bool) -> Target? {
        guard let window else { return nil }
        for space in spaces.values {
            guard let anchor = space.anchor, anchor.window === window, !space.zones.isEmpty else { continue }
            // The visible list, minus the toolbar / title bar the content scrolls under.
            let clip = anchor.convert(anchor.visibleRect, to: nil).intersection(window.contentLayoutRect)
            guard clip.contains(point) else { continue }
            var byKey: [String: Target] = [:]
            var list: [MailInboxRules.DropZone] = []
            for (target, rect) in space.zones where accepts(target) {
                byKey[target.key] = target
                list.append(MailInboxRules.DropZone(id: target.key, rect: anchor.convert(rect, to: nil),
                                                    priority: target.priority))
            }
            if let hit = MailInboxRules.pick(point, zones: list, clip: clip).flatMap({ byKey[$0] }) { return hit }
        }
        return nil
    }

    func setHovered(_ target: Target?) {
        if hovered != target { hovered = target }
    }
}

nonisolated private struct MailDropSpaceKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The drop space of the enclosing Mail inbox list (nil → rows register no zone).
    nonisolated var mailDropSpace: String? {
        get { self[MailDropSpaceKey.self] }
        set { self[MailDropSpaceKey.self] = newValue }
    }
}

// MARK: - Anchor

/// Invisible, flipped AppKit view placed as the background of the inbox list: its bounds are the
/// list's named coordinate space, so `convert(_:to: nil)` maps registered frames to the window.
struct DropSpaceAnchor: NSViewRepresentable {
    let registry: DropTargetRegistry
    let space: String

    final class Coordinator {
        let registry: DropTargetRegistry
        var space: String
        init(registry: DropTargetRegistry, space: String) { self.registry = registry; self.space = space }
    }

    func makeCoordinator() -> Coordinator { Coordinator(registry: registry, space: space) }

    func makeNSView(context: Context) -> DropSpaceAnchorView {
        let view = DropSpaceAnchorView()
        registry.setAnchor(view, space: space)
        return view
    }

    func updateNSView(_ view: DropSpaceAnchorView, context: Context) {
        context.coordinator.space = space
        registry.setAnchor(view, space: space)
    }

    static func dismantleNSView(_ view: DropSpaceAnchorView, coordinator: Coordinator) {
        coordinator.registry.removeSpace(coordinator.space, anchor: view)
    }
}

final class DropSpaceAnchorView: NSView {
    override var isFlipped: Bool { true }
    // Never takes clicks, drags or the cursor from the SwiftUI content above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Registers this view's frame as a drop zone of the enclosing inbox list while it is on screen.
    func dropZone(_ target: DropTargetRegistry.Target?, registry: DropTargetRegistry = .shared) -> some View {
        modifier(DropZoneModifier(target: target, registry: registry))
    }
}

private struct DropZoneModifier: ViewModifier {
    let target: DropTargetRegistry.Target?
    let registry: DropTargetRegistry
    @Environment(\.mailDropSpace) private var space

    func body(content: Content) -> some View {
        if let target, let space {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DropTargetRegistry.space)) } action: { rect in
                    registry.register(target, rect: rect, space: space)
                }
                .onDisappear { registry.unregister(target, space: space) }
        } else {
            content
        }
    }
}

// MARK: - Emails in a drag

/// Email files and email promises in a drag (Finder `.eml`, New Outlook message drags). PDFs,
/// folders and links keep going through `DropIntake`.
enum MailDropIntake {
    struct Collected {
        var items: [IntakeItem] = []
        var ignored: [String] = []
        var emails: [URL] = []
        /// The emails are promise copies under incoming/ (delete after the import).
        var temporaryEmails = false
    }

    static func isEmail(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "eml" { return !DropIntake.isFolder(url) }
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return t.conforms(to: .emailMessage) && !t.conforms(to: .directory)
        }
        return false
    }

    static func emailFiles(_ pb: NSPasteboard) -> [URL] { DropIntake.fileURLs(pb).filter(isEmail) }

    /// Promises that announce an email type (the untyped ones are sorted out after receiving).
    static func emailPromiseCount(_ pb: NSPasteboard) -> Int {
        receivers(pb).filter { r in r.fileTypes.contains { isEmailType($0) } }.count
    }

    private static func isEmailType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .emailMessage) ?? false
    }

    private static func receivers(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// Like `DropIntake.collect`, with emails split out: file URLs → emails / PDFs & folders /
    /// ignored; promises (PDF, email or untyped) → received into `incoming`, then sorted by
    /// content; otherwise PDF data or links via `DropIntake`. `completion` runs on the main actor.
    static func collect(_ pb: NSPasteboard, incoming: URL, completion: @escaping @MainActor (Collected) -> Void) {
        let files = DropIntake.fileURLs(pb)
        if !files.isEmpty {
            var c = Collected()
            for url in files {
                if isEmail(url) { c.emails.append(url) }
                else if DropIntake.isFolder(url) || DropIntake.isPDF(url) { c.items.append(.file(url)) }
                else { c.ignored.append(url.lastPathComponent) }
            }
            completion(c)
            return
        }
        let promised = receivers(pb).filter { r in
            r.fileTypes.isEmpty || r.fileTypes.contains { isEmailType($0) || (UTType($0)?.conforms(to: .pdf) ?? false) }
        }
        guard !promised.isEmpty else {
            DropIntake.collect(pb, incoming: incoming) { items, ignored in
                completion(Collected(items: items, ignored: ignored))
            }
            return
        }
        let dir = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PromiseReceiving.receive(promised, into: dir) { urls in
            MainActor.assumeIsolated {
                var c = Collected(temporaryEmails: true)
                for url in urls {
                    if DropIntake.isPDF(url) || (try? FileOps.checkPDF(url)) != nil { c.items.append(.promised(url)) }
                    else if isEmail(url) || looksLikeEmail(url) { c.emails.append(url) }
                    else { c.ignored.append(url.lastPathComponent) }
                }
                completion(c)
            }
        }
    }

    /// An RFC 5322 message: the first lines are headers and include From: or Message-ID:.
    static func looksLikeEmail(_ url: URL) -> Bool {
        guard let head = try? FileOps.readHead(url, bytes: 8192) else { return false }
        return looksLikeEmail(head: head)
    }

    static func looksLikeEmail(head: Data) -> Bool {
        let text = String(decoding: head, as: UTF8.self)
        var sawHeader = false
        var sawKey = false
        for raw in text.split(separator: "\n", maxSplits: 80, omittingEmptySubsequences: false).prefix(80) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            if line.isEmpty { break }                               // end of the header block
            if line.first == " " || line.first == "\t" { continue } // folded header
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return false }
            let name = line[..<colon].lowercased()
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
            sawHeader = true
            if ["from", "message-id", "received", "return-path"].contains(name) { sawKey = true }
        }
        return sawHeader && sawKey
    }

    /// Deletes received promise copies (only inside `incoming`).
    nonisolated static func removeTemporary(_ urls: [URL], incoming: URL) {
        let root = incoming.standardizedFileURL.path + "/"
        var dirs = Set<URL>()
        for url in urls where url.standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: url)
            dirs.insert(url.deletingLastPathComponent())
        }
        for dir in dirs where dir.standardizedFileURL.path.hasPrefix(root)
            && ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? false) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
