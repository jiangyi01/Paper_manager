import AppKit
import PaperDeckCore

/// The Services entries (Info.plist `NSServices`): "Explain with PaperDeck" (`explainText`; also
/// `explainSelection`), "Ask PaperDeck…" (`askText`) and "Translate with PaperDeck"
/// (`translateSelection`). The selection arrives on the Services' private pasteboard — no
/// permission, no pasteboard prompt. A Services call never sends by itself (phase-3 fix F10: any
/// local process can invoke a service without the user): "Explain" / "Translate" open the panel with
/// the selection held at [Send] — that click or ⏎ in the panel mints the ticket — and "Ask
/// PaperDeck…" opens it with the question field. The calling app and its window go with the
/// capture (privacy: a mail / chat app or a webmail window asks first). Installed as
/// `NSApp.servicesProvider` only once Explain is available (`ExplainBootstrap`); a call that arrives
/// before the library is open (a cold launch) waits in `pending`, like the app's pending opens.
/// Owned by the Explain UI lane (A2).
final class ExplainServiceProvider: NSObject {
    /// A Services call waiting for the coordinator.
    enum Request {
        case explain(ExplainCapture, ExplainTurnKind)
        case ask(ExplainCapture)
    }

    private weak var coordinator: ExplainCoordinator?
    private(set) var pending: [Request] = []
    /// At most this many queued calls (the oldest are dropped).
    static let pendingLimit = 4

    init(coordinator: ExplainCoordinator?) {
        self.coordinator = coordinator
        super.init()
    }

    /// The coordinator exists now: queued calls are delivered (each opens held; nothing is sent).
    func attach(_ coordinator: ExplainCoordinator) {
        self.coordinator = coordinator
        let queued = pending
        pending.removeAll()
        queued.forEach(deliver)
    }

    /// NSServices `explainText`: the selection is exact text; the panel holds it at [Send].
    @objc func explainText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard, kind: .explain, error: error)
    }

    /// Same as `explainText` (the name the Explain design uses).
    @objc func explainSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard, kind: userData == "translate" ? .translate : .explain, error: error)
    }

    /// "Translate with PaperDeck".
    @objc func translateSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard, kind: .translate, error: error)
    }

    /// NSServices `askText`: the panel opens with the selection quoted and the question field
    /// focused; the question's Return is its own gesture.
    @objc func askText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let capture = Self.capture(pboard) else {
            error.pointee = L.Explain.serviceNoText as NSString
            return
        }
        deliver(.ask(capture))
    }

    private func receive(_ pboard: NSPasteboard, kind: ExplainTurnKind, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let capture = Self.capture(pboard) else {
            error.pointee = L.Explain.serviceNoText as NSString
            return
        }
        deliver(.explain(capture, kind))
    }

    private func deliver(_ r: Request) {
        guard let coordinator else {
            pending.append(r)
            if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
            return
        }
        switch r {
        case .explain(let capture, let kind):
            coordinator.holdForSend(capture: capture, kind: kind)
        case .ask(let capture):
            coordinator.openForQuestion(capture: capture)
        }
    }

    /// The service's text (normalized), with the app that offered it and its front window's title
    /// (privacy: a mail / chat app or a webmail window asks first; the title also locates the paper).
    static func capture(_ pboard: NSPasteboard) -> ExplainCapture? {
        guard let raw = pboard.string(forType: .string), let text = ClipboardOffer.normalize(raw) else { return nil }
        let host = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let window = WindowTitleReader.frontmostWindow()
        return ExplainCapture(source: .services, text: text, hostBundleID: host,
                              windowTitle: window?.bundleID == host ? window?.title : nil)
    }
}
