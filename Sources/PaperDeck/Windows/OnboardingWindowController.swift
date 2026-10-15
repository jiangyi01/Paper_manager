import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The setup window (820×600, minimum 760×560) in its three modes:
/// - **preflight** — a fresh install before the library exists (`runPreflight()`), Welcome →
///   About you → AI → Library; the commit opens the engine;
/// - **live** — right after the preflight, or `setup.completed == false` with a library;
/// - **revisit** — Help ▸ Setup Assistant…, Settings ▸ General, `paperdeck://setup`: every page
///   shows the current values; nothing destructive.
/// `onboarding.legacy` (developer rollback) hosts the old Setup Assistant instead.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let guide: GuideStore
    private let facts: SetupFactsCollector
    private var window: NSWindow?
    private var model: OnboardingModel?
    private var preflightContinuation: CheckedContinuation<PreflightResult?, Never>?
    private weak var state: AppState?
    /// The old Setup Assistant (`onboarding.legacy`).
    private var legacy: SetupWindowController?
    /// What Finish asks for afterwards (installed by AppDelegate).
    var onFinished: (OnboardingModel.FinishChoice) -> Void = { _ in }

    init(settings: SettingsStore, guide: GuideStore, facts: SetupFactsCollector) {
        self.settings = settings
        self.guide = guide
        self.facts = facts
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// A language switch (its own 中文 / English button, Settings): the window's title, as the
    /// Window menu lists it.
    func relocalizeTitle() {
        window?.title = model?.mode == .revisit ? L.Onb.revisitTitle : L.Onb.windowTitle
    }

    // MARK: Preflight

    /// Shows the preflight and waits for its commit (the keys are written; the engine opens next)
    /// or for Quit (nil).
    func runPreflight(pendingOpens: Int) async -> PreflightResult? {
        let m = makeModel(.preflight)
        m.pendingOpens = pendingOpens
        present(m)
        return await withCheckedContinuation { cont in preflightContinuation = cont }
    }

    /// A file arrived (cold "Open With") while the preflight is up: Welcome says how many wait.
    func setPendingOpens(_ n: Int) {
        if let model, model.mode == .preflight { model.pendingOpens = n }
    }

    private func finishPreflight(_ result: PreflightResult?) {
        let cont = preflightContinuation
        preflightContinuation = nil
        cont?.resume(returning: result)
    }

    // MARK: Live / revisit

    /// The engine is open: a preflight window continues in live mode at Daily plan (Finish after
    /// Quick Start).
    func attach(_ state: AppState) {
        self.state = state
        if let model, model.mode == .preflight { model.didOpenLibrary() }
    }

    /// `resume`: the page to show (nil: the first page of the mode). Live while setup isn't
    /// completed, revisit afterwards.
    func show(resume page: OnboardingPage? = nil) {
        if settings.config.legacyOnboardingFlag, let state {
            let old = legacy ?? SetupWindowController(state: state)
            legacy = old
            old.show()
            return
        }
        if let model, isVisible {
            if let page, model.canJump(to: page) || model.mode == .revisit { model.go(page) }
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let m = makeModel(settings.setupCompleted ? .revisit : .live)
        if let page, m.pages.contains(page) { m.go(page) }
        present(m)
    }

    private func makeModel(_ mode: OnboardingModel.Mode) -> OnboardingModel {
        let m = OnboardingModel(settings: settings, guide: guide, facts: facts, mode: mode)
        m.onCommit = { [weak self] result in self?.finishPreflight(result) }
        m.onFinish = { [weak self] choice in self?.finished(choice) }
        model = m
        return m
    }

    private func finished(_ choice: OnboardingModel.FinishChoice) {
        let revisit = model?.mode == .revisit
        window?.close()
        // Revisit ▸ Done just closes; the first Finish lands in the library (as the old assistant did).
        if revisit && choice == .close { return }
        onFinished(choice)
    }

    // MARK: Window

    private func present(_ m: OnboardingModel) {
        let w = window ?? makeWindow()
        (w.contentViewController as? NSHostingController<OnboardingView>)?.rootView = OnboardingView(model: m)
        w.title = m.mode == .revisit ? L.Onb.revisitTitle : L.Onb.windowTitle
        ActivationPolicy.becomeRegular()
        if let state { LibraryMainMenu.installIfNeeded(state: state) } else { LibraryMainMenu.installStandalone() }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: model ?? makeModel(.revisit)))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.identifier = ActivationPolicy.onboarding
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 760, height: 560)
        w.setContentSize(NSSize(width: 820, height: 600))
        w.center()
        w.delegate = self
        window = w
        return w
    }

    /// Preflight: closing means "Quit PaperDeck?". Live: "finish later" (it reopens next launch).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.mode == .preflight, preflightContinuation != nil else { return true }
        guard model?.committing != true else { return false }
        let alert = NSAlert()
        alert.messageText = L.Onb.quitTitle
        alert.informativeText = L.Onb.quitBody
        alert.addButton(withTitle: L.Onb.quit)
        alert.addButton(withTitle: L.Onb.keepSettingUp)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        finishPreflight(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicy.update(closing: window)
    }
}
