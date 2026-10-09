import CoreGraphics
import Foundation
import PaperDeckCore
import ScreenCaptureKit

/// Freezes every display for Explain's overlay (dive-capture §3): one ScreenCaptureKit still per
/// display at full Retina resolution (`pointPixelScale`), the cursor hidden, SDR sRGB — excluding
/// only PaperDeck's own overlay and panel windows (`excludingWindowIDs`), so PaperDeck's reader
/// and library can be explained too. Not `NSWindow.sharingType` (ignored since macOS 15): the
/// filter is the mechanism. The stills stay in memory and are dropped with the overlay.
///
/// Runs only on the App path after `preflight()` (`CaptureFlow.freeze` checks it first); asking
/// is `ScreenPermission.request`'s explicit button. Never used by tests (they inject fakes).
nonisolated struct ScreenCapturer: ScreenCapturing {
    /// Never prompts.
    func preflight() -> Bool { CGPreflightScreenCaptureAccess() }

    func request() async -> Bool {
        await MainActor.run { ScreenPermission.request() }
    }

    func freeze(excludingWindowIDs ids: [CGWindowID]) async throws -> FrozenScreens {
        guard preflight() else { throw CaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        let excluded = Set(ids)
        let ours = content.windows.filter { excluded.contains($0.windowID) }
        var displays: [FrozenDisplay] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: ours)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                displays.append(FrozenDisplay(id: display.displayID, frame: display.frame, scale: scale, image: image))
            } catch {
                // A display that sleeps mid-capture: the others still work; a refusal stops it all.
                let mapped = Self.map(error)
                if mapped == .permissionDenied { throw mapped }
            }
        }
        guard !displays.isEmpty else { throw CaptureError.noDisplays }
        return FrozenScreens(displays: displays)
    }

    /// The user declined (or revoked) Screen Recording → `.permissionDenied`; anything else by
    /// its type only (no content in errors).
    static func map(_ error: any Error) -> CaptureError {
        if let e = error as? SCStreamError, e.code == .userDeclined { return .permissionDenied }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userDeclined.rawValue { return .permissionDenied }
        return .failed("\(ns.domain)#\(ns.code)")
    }
}
