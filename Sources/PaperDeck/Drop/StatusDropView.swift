import AppKit
import PaperDeckCore

/// Transparent overlay on the status-item button that accepts PDF drops.
/// Clicks are forwarded to the button so its menu still opens normally.
final class StatusDropView: NSView {
    weak var button: NSStatusBarButton?
    var onDrop: (([IntakeItem], _ ignoredNames: [String]) -> Void)?
    var incomingDirectory: () -> URL = { AppPaths.production().incoming }
    private var highlighted = false { didSet { button?.highlight(highlighted) } }

    init(button: NSStatusBarButton) {
        self.button = button
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes(DropIntake.registeredTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { button?.performClick(nil) }
    override func rightMouseDown(with event: NSEvent) { button?.performClick(nil) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let ok = DropIntake.summarize(pb).isAcceptable || !MailDropIntake.emailFiles(pb).isEmpty
            || (DropIntake.fileURLs(pb).isEmpty && MailDropIntake.emailPromiseCount(pb) > 0)
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        // An all-image drag goes to Explain (R-UI-2); anything with a PDF, folder or email imports as before.
        if DropIntake.routeImageDropToExplain(sender.draggingPasteboard, incoming: incomingDirectory(), near: window?.frame) {
            return true
        }
        let handler = onDrop
        // Emails dropped on the icon become Mail cards (DropTargetRegistry.onMailFiles, installed by AppState).
        MailDropIntake.collect(sender.draggingPasteboard, incoming: incomingDirectory()) { c in
            var ignored = c.ignored
            if !c.emails.isEmpty {
                if let onMail = DropTargetRegistry.shared.onMailFiles { onMail(c.emails, c.temporaryEmails) }
                else { ignored += c.emails.map(\.lastPathComponent) }
            }
            if !c.items.isEmpty || !ignored.isEmpty || c.emails.isEmpty { handler?(c.items, ignored) }
        }
        return true
    }
}
