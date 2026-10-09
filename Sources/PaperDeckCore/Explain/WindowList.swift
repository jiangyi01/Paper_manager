import CoreGraphics
import Foundation

/// The window under a point, from `CGWindowListCopyWindowInfo`'s dictionaries (front to back).
/// Pure: the App reads the list (`WindowTitleReader`); tests feed synthetic dictionaries. Titles
/// (`kCGWindowName`) are present only with Screen Recording; they stay on this Mac — used to
/// locate the paper and to spot a mail window, never sent to a model.
package enum WindowList {
    package struct Entry: Sendable, Equatable {
        package var windowID: CGWindowID
        package var ownerPID: Int32
        package var ownerName: String?
        package var title: String?
        /// Global (Quartz) points.
        package var bounds: CGRect
        /// 0 = normal application windows (menus, the Dock, overlays sit higher).
        package var layer: Int
        package var alpha: Double

        package init(windowID: CGWindowID, ownerPID: Int32, ownerName: String? = nil, title: String? = nil,
                     bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
            self.windowID = windowID; self.ownerPID = ownerPID; self.ownerName = ownerName; self.title = title
            self.bounds = bounds; self.layer = layer; self.alpha = alpha
        }
    }

    /// The `kCGWindow…` dictionaries as entries (malformed ones skipped), order kept.
    package static func entries(from info: [[String: Any]]) -> [Entry] {
        info.compactMap { d in
            guard let number = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let title = (d[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Entry(windowID: number, ownerPID: pid, ownerName: d[kCGWindowOwnerName as String] as? String, title: title,
                         bounds: bounds, layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                         alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// The frontmost normal, visible window containing `point` that isn't ours.
    package static func window(at point: CGPoint, in entries: [Entry], excludingPID: Int32) -> Entry? {
        entries.first { $0.layer == 0 && $0.alpha > 0.01 && $0.ownerPID != excludingPID && $0.bounds.contains(point)
            && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
    }

    /// The frontmost normal window of `pid` (text triggers: the frontmost app's window).
    package static func frontmostWindow(ofPID pid: Int32, in entries: [Entry]) -> Entry? {
        entries.first { $0.layer == 0 && $0.alpha > 0.01 && $0.ownerPID == pid && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
    }
}
