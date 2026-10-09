import AppKit
import SwiftUI
import PaperDeckCore

/// Hover state of a drop target, observed by SwiftUI overlays.
@Observable
final class DropTargetState {
    var isTargeted = false
    /// PDFs / folders / links in the drag (`.eml` files are counted in `mailFiles`, not `otherFiles`).
    var summary = DropIntake.Summary()
    /// Emails in the drag (.eml files, email-typed promises) — they go to the Mail import.
    var mailFiles = 0
    /// The Mail row / card under the pointer (`DropTargetRegistry`); nil → the generic import.
    var target: DropTargetRegistry.Target?
}

/// NSHostingView that accepts PDF drops (files, folders, promises, PDF data,
/// links). SwiftUI's drop modifiers cannot receive file promises, so both the
/// floating panel and the library window use this as their content view.
///
/// Mail (MAIL_DESIGN Part A §3): while a PDF-only drag hovers a zone registered in
/// `DropTargetRegistry` (a paper row or an email card of the inbox), that zone is targeted and
/// the drop goes to `registry.onTargetedDrop`; dropped emails (.eml files / promises) go to
/// `registry.onMailFiles` from anywhere in the window or panel; everything else keeps going to
/// `onDrop` (the generic import).
final class DropHostingView<Content: View>: NSHostingView<Content> {
    let dropState = DropTargetState()
    /// Called with the collected items (on the main actor).
    var onDrop: (([IntakeItem], _ ignoredNames: [String]) -> Void)?
    var incomingDirectory: () -> URL = { AppPaths.production().incoming }
    var registry: DropTargetRegistry = .shared

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropIntake.registeredTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Borderless panels: the first click should hit SwiftUI buttons directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        var s = DropIntake.summarize(pb)
        var mail = MailDropIntake.emailFiles(pb).count
        if mail > 0 {
            s.otherFiles = max(0, s.otherFiles - mail)
        } else if DropIntake.fileURLs(pb).isEmpty {
            mail = MailDropIntake.emailPromiseCount(pb)
        }
        dropState.summary = s
        dropState.mailFiles = mail
        dropState.isTargeted = s.isAcceptable || mail > 0
        updateTarget(sender)
        return dropState.isTargeted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
        return dropState.isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropState.isTargeted = false
        clearTarget()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropState.isTargeted }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // An all-image drag goes to Explain (R-UI-2); anything with a PDF, folder or email imports as before.
        if DropIntake.routeImageDropToExplain(sender.draggingPasteboard, incoming: incomingDirectory(), near: window?.frame) {
            dropState.isTargeted = false
            clearTarget()
            return true
        }
        updateTarget(sender)
        let target = dropState.target
        dropState.isTargeted = false
        clearTarget()
        let handler = onDrop
        let registry = self.registry
        MailDropIntake.collect(sender.draggingPasteboard, incoming: incomingDirectory()) { c in
            var ignored = c.ignored
            if !c.emails.isEmpty {
                if let onMail = registry.onMailFiles {
                    onMail(c.emails, c.temporaryEmails)
                } else {
                    ignored += c.emails.map(\.lastPathComponent)
                }
            }
            if let target, !c.items.isEmpty, let targeted = registry.onTargetedDrop {
                targeted(target, c.items, ignored)
            } else if !c.items.isEmpty || !ignored.isEmpty || c.emails.isEmpty {
                // Emails alone never reach the generic import ("nothing importable" would be wrong).
                handler?(c.items, ignored)
            }
        }
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        dropState.isTargeted = false
        clearTarget()
    }

    // MARK: Mail drop zones

    /// Only PDF-only drags target a zone: a row takes exactly one PDF, a card one or more.
    private func updateTarget(_ sender: any NSDraggingInfo) {
        let s = dropState.summary
        let pdfs = s.pdfFiles + s.promises + (s.pdfData ? 1 : 0)
        guard dropState.isTargeted, pdfs > 0, s.folders == 0, s.links == 0, dropState.mailFiles == 0,
              registry.hasZones else {
            clearTarget()
            return
        }
        let target = registry.target(at: sender.draggingLocation, in: window) { t in
            switch t {
            case .mailItem: return pdfs == 1
            case .mailCard: return true
            }
        }
        if dropState.target != target { dropState.target = target }
        registry.setHovered(target)
    }

    private func clearTarget() {
        guard dropState.target != nil else { return }
        dropState.target = nil
        registry.setHovered(nil)
    }
}
