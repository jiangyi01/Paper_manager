import AppKit

/// Detects that the user started dragging something importable anywhere on
/// screen, so the floating panel can pop open before the cursor arrives.
///
/// Global mouse monitors need no Accessibility permission (only key monitors
/// do). We only look at the drag pasteboard's *types* and change count.
final class DragMonitor {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var lastChangeCount = NSPasteboard(name: .drag).changeCount
    private var lastCheck = Date.distantPast
    private(set) var isDragging = false

    func start() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.dragged()
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.ended()
        }
    }

    func stop() {
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        if let m = upMonitor { NSEvent.removeMonitor(m) }
        dragMonitor = nil
        upMonitor = nil
    }

    private func dragged() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.1 else { return }   // ≤ 10 Hz
        lastCheck = now
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard DropIntake.looksImportable(types: pb.types ?? []) else { return }
        isDragging = true
        onDragBegan?()
    }

    private func ended() {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
    }
}
