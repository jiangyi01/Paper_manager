import AppKit
import Observation
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// What the preflight hands the launch (`AppDelegate.bootstrap`): the library is chosen and its
/// keys are written; the engine opens next.
struct PreflightResult: Equatable {
    /// The field's starter categories for a new library (applied only if the index is pristine).
    var starterPack: [StarterCategory]?
    /// An existing library was chosen: index it from its card.json files before `start()`.
    var existingLibrary: Bool
    /// Quick Start: the window jumps to Finish once the engine is open.
    var quickStart: Bool
}

/// The setup window's model: mode, pages, the preflight draft and its single commit.
/// Preflight writes only `language` and the profile keys before the commit; `library.path`,
/// `agent.*` and `onboarding.aiDecision` are written by `commit()` (so quitting earlier leaves
/// the gate open and the next launch starts the preflight again).
@Observable
final class OnboardingModel {
    enum Mode: Equatable { case preflight, live, revisit }

    enum LibraryChoice: Equatable {
        case documents, homeFolder
        case other(URL)
        case existing(URL)
    }

    enum LibraryProblem: Equatable { case denied, missingParent, readOnly }

    enum MailStep: Equatable { case ask, routes, m365, guide, senders }

    enum FinishChoice { case tour, library, close }

    let settings: SettingsStore
    let guide: GuideStore
    let facts: SetupFactsCollector
    var state: AppState? { facts.state }

    var mode: Mode
    var page: OnboardingPage = .welcome
    private(set) var visited: Set<OnboardingPage> = [.welcome]
    var skippedPages: Set<OnboardingPage> = []
    /// Live mode right after a preflight in this launch (its pages are done).
    var preflightDone = false
    var quickStart = false

    // P1
    var pendingOpens = 0
    var movingFromAnotherMac = false
    var showImportSheet = false

    // P3 — in preflight a draft until the commit; live / revisit write at once.
    var aiChoice: OnboardingRules.AIChoice?
    var aiTurnedOn = false
    var askContinueWithoutAI = false
    @ObservationIgnored private var aiPreselected = false

    // P4 (preflight)
    var libraryChoice: LibraryChoice = .documents
    var inspected: LibraryFolderKind?
    var libraryProblem: LibraryProblem?
    var committing = false
    var documentsInICloud = false

    // P6
    var mailStep: MailStep = .ask
    var mailRoute: OnboardingRules.MailRoute?
    var m365Answer: OnboardingRules.M365Answer?
    var mailSheet: MailSourceID?
    var advisorAddress = ""
    var senderAdded = false

    // P8
    var showChecklistOnToday = true

    // The controller's hooks.
    @ObservationIgnored var onCommit: ((PreflightResult) -> Void)?
    @ObservationIgnored var onFinish: ((FinishChoice) -> Void)?

    /// Where a new library goes by default and the home-folder alternative.
    static var documentsLibrary: URL { AppPaths.production().library }
    static var homeLibrary: URL { SharedPaths.realHome.appendingPathComponent("PaperDeck", isDirectory: true) }

    init(settings: SettingsStore, guide: GuideStore, facts: SetupFactsCollector, mode: Mode) {
        self.settings = settings
        self.guide = guide
        self.facts = facts
        self.mode = mode
        self.page = pages.first ?? .welcome
    }

    // MARK: Pages

    /// The pages this mode walks through (the rail always lists all eight).
    var pages: [OnboardingPage] {
        switch mode {
        case .preflight: return [.welcome, .about, .ai, .library]
        case .live: return preflightDone ? [.plan, .mail, .importPapers, .finish] : OnboardingPage.allCases
        case .revisit: return OnboardingPage.allCases
        }
    }

    var isOptional: Bool { page == .mail || page == .importPapers }

    func canJump(to p: OnboardingPage) -> Bool {
        guard pages.contains(p) else { return false }
        return mode == .revisit || visited.contains(p)
    }

    func go(_ p: OnboardingPage) {
        guard pages.contains(p) else { return }
        page = p
        visited.insert(p)
    }

    var canGoBack: Bool { (pages.firstIndex(of: page) ?? 0) > 0 && !committing }

    func back() {
        guard let i = pages.firstIndex(of: page), i > 0 else { return }
        go(pages[i - 1])
    }

    /// Continue (Return). Some pages ask first (AI) or commit (Library in preflight).
    func next() {
        // Revisit only navigates: walking through the pages never records a decision.
        if mode == .revisit {
            if page == .finish { finish(.close) } else { advance() }
            return
        }
        switch page {
        case .ai:
            if aiChoice?.provider != nil, !aiIsOn {
                askContinueWithoutAI = true
                return
            }
            if !aiIsOn { recordAIDecision(.none) }
        case .library where mode == .preflight:
            Task { await commit() }
            return
        case .mail:
            if guide.mailDecision == nil { guide.mailDecision = OnboardingRules.MailDecision.skipped.rawValue }
        case .finish:
            finish(.close)
            return
        default:
            break
        }
        advance()
    }

    /// Skip (Mail, Import).
    func skip() {
        skippedPages.insert(page)
        if mode != .revisit, page == .mail, guide.mailDecision == nil {
            guide.mailDecision = OnboardingRules.MailDecision.skipped.rawValue
        }
        advance()
    }

    private func advance() {
        guard let i = pages.firstIndex(of: page), i + 1 < pages.count else { return }
        go(pages[i + 1])
    }

    // MARK: Rail

    /// ✓ done (live check) / ● current / ○ to do / – skipped / ⚠ problem.
    func railState(_ p: OnboardingPage) -> CheckState {
        let f = facts.facts
        switch p {
        case .welcome: return visited.count > 1 || mode != .preflight ? .done : .todo
        case .about: return f.profile.fieldID != nil && f.profile.organizationID != nil || (visited.contains(.ai) && mode == .preflight) ? .done : .todo
        case .ai: return aiDecided ? .done : .todo
        case .library:
            if mode == .preflight { return libraryProblem != nil ? .problem(LocalizedText(L.Onb.deniedInline)) : .todo }
            return GuideEvaluator.evaluate(.libraryUsable, f)
        case .plan: return visited.contains(.plan) && page != .plan ? .done : .todo
        case .mail:
            if skippedPages.contains(.mail) { return .notApplicable }
            return guide.mailDecision != nil ? .done : .todo
        case .importPapers:
            if skippedPages.contains(.importPapers) { return .notApplicable }
            return visited.contains(.importPapers) && page != .importPapers ? .done : .todo
        case .finish: return settings.setupCompleted && mode != .revisit ? .done : .todo
        }
    }

    // MARK: AI (P3)

    var aiIsOn: Bool {
        mode == .preflight ? aiTurnedOn : AgentMode(rawValue: settings.agentMode)?.providerKind != nil
    }

    var aiDecided: Bool {
        if mode == .preflight { return aiTurnedOn || draftAIDecision == OnboardingRules.AIChoice.none }
        return OnboardingRules.aiDecided(mode: AgentMode(rawValue: settings.agentMode) ?? .off, decision: guide.aiDecision)
    }

    /// Fresh installs only, once both providers are known; never writes.
    func preselectAI() {
        guard !aiPreselected, aiChoice == nil else { return }
        if mode != .preflight {
            // Live / revisit: what the settings say.
            if let k = AgentMode(rawValue: settings.agentMode)?.providerKind { aiChoice = k == .claude ? .claude : .codex }
            else if guide.aiDecision == "none" { aiChoice = OnboardingRules.AIChoice.none }
            else { aiChoice = settings.agentProvider == .claude ? .claude : .codex }
            aiPreselected = true
            return
        }
        let f = facts.facts
        if let pick = OnboardingRules.preselect(claude: f.ai.statuses[.claude], codex: f.ai.statuses[.codex]) {
            aiChoice = pick
            aiPreselected = true
        }
    }

    /// A card was clicked: the provider preference (preflight: the draft).
    func selectAI(_ choice: OnboardingRules.AIChoice) {
        aiChoice = choice
        guard mode != .preflight else {
            if choice == .none { aiTurnedOn = false }
            return
        }
        if let k = choice.provider { state?.selectProvider(k) }
        if choice == .none {
            state?.setAIReading(false)
            recordAIDecision(.none)
        }
    }

    /// [Turn On ‹provider› Reading] — the only way `agent.mode` becomes claude / codex.
    func turnOnAI() {
        guard let k = aiChoice?.provider else { return }
        if mode == .preflight {
            aiTurnedOn = true
            return
        }
        state?.selectProvider(k)
        state?.setAIReading(true)
        recordAIDecision(k == .claude ? .claude : .codex)
    }

    func turnOffAI() {
        if mode == .preflight { aiTurnedOn = false; return }
        state?.setAIReading(false)
    }

    /// "Continue without AI for now?" → Continue Without AI.
    func continueWithoutAI() {
        askContinueWithoutAI = false
        aiTurnedOn = false
        recordAIDecision(.none)
        advance()
    }

    /// "Continue without AI for now?" → Turn On….
    func turnOnAndContinue() {
        askContinueWithoutAI = false
        turnOnAI()
        advance()
    }

    private func recordAIDecision(_ d: OnboardingRules.AIChoice) {
        // Preflight: the decision is part of the commit (a quit before it leaves nothing behind).
        if mode == .preflight { draftAIDecision = d; return }
        guide.aiDecision = d.rawValue
    }
    /// Preflight: the AI page's decision until the commit writes it.
    private(set) var draftAIDecision: OnboardingRules.AIChoice?

    // MARK: Library (P4)

    var libraryTarget: URL {
        switch libraryChoice {
        case .documents: Self.documentsLibrary
        case .homeFolder: Self.homeLibrary
        case .other(let u), .existing(let u): u
        }
    }

    /// Picks a folder for "another folder" / "existing library" (bounded inspection).
    func pickLibraryFolder(existing: Bool) async {
        guard let picked = await LibraryFolderPicker.pick(
            startingAt: SharedPaths.realHome, prompt: existing ? L.Onb.useIt : L.Onb.chooseFolderPrompt) else { return }
        applyPicked(picked.url, kind: picked.kind, existing: existing)
    }

    /// The decision after a folder was picked and inspected (also the self-test's seam).
    func applyPicked(_ url: URL, kind: LibraryFolderKind, existing: Bool) {
        libraryProblem = nil
        inspected = kind
        switch kind {
        case .existingLibrary:
            libraryChoice = .existing(url)
        case .parentOfLibrary(let child, _):
            libraryChoice = existing ? .existing(child) : .other(url)
            if !existing { inspected = .otherContent(items: 1) }
        default:
            libraryChoice = existing ? .existing(url) : .other(url)
        }
    }

    /// The commit at the Library page's Continue: probe (macOS asks for Documents access here),
    /// create the folder, then write every held-back key in one go.
    func commit(prepare: (URL, Bool) async -> LibraryCommit.Outcome = LibraryCommit.prepare) async {
        guard mode == .preflight, !committing else { return }
        if case .existing = libraryChoice, !Self.isExistingLibrary(inspected) {
            libraryProblem = nil
            return              // "No PaperDeck library here": the page offers Choose Another / Create Here
        }
        committing = true
        libraryProblem = nil
        let target = libraryTarget
        let isExisting: Bool = { if case .existing = libraryChoice { return true }; return false }()
        switch await prepare(target, !isExisting) {
        case .ok: break
        case .denied: libraryProblem = .denied; committing = false; return
        case .missingParent: libraryProblem = .missingParent; committing = false; return
        case .readOnly: libraryProblem = .readOnly; committing = false; return
        }
        settings.libraryPath = target.path
        if let k = aiChoice?.provider { settings.agentProvider = k }
        if aiTurnedOn, let k = aiChoice?.provider { settings.agentMode = k.rawValue }
        // Past the AI page every path is a decision: reading turned on, or "not now".
        let decision: OnboardingRules.AIChoice = aiTurnedOn ? (aiChoice ?? OnboardingRules.AIChoice.none) : OnboardingRules.AIChoice.none
        guide.aiDecision = decision.rawValue
        if quickStart { guide.mailDecision = OnboardingRules.MailDecision.skipped.rawValue }
        let starter = isExisting ? nil : settings.config.snapshot.field.starterCategories
        onCommit?(PreflightResult(starterPack: starter, existingLibrary: isExisting, quickStart: quickStart))
    }

    static func isExistingLibrary(_ k: LibraryFolderKind?) -> Bool {
        if case .existingLibrary? = k { return true }
        return false
    }

    /// Quick Start (Welcome): general field, no institution, the Documents library, no AI, mail
    /// skipped — then straight to Finish once the library is open.
    func runQuickStart(prepare: (URL, Bool) async -> LibraryCommit.Outcome = LibraryCommit.prepare) async {
        guard mode == .preflight else { return }
        quickStart = true
        settings.config.fieldID = FieldPresets.general.id
        settings.config.organizationID = OrganizationPresets.generic.id
        aiChoice = OnboardingRules.AIChoice.none
        aiTurnedOn = false
        libraryChoice = .documents
        inspected = nil
        go(.library)
        await commit(prepare: prepare)
        if libraryProblem != nil { quickStart = false }
    }

    /// The engine opened: the window continues in live mode.
    func didOpenLibrary() {
        committing = false
        mode = .live
        preflightDone = true
        visited.formUnion([.welcome, .about, .ai, .library])
        go(quickStart ? .finish : .plan)
    }

    // MARK: Mail (P6)

    func chooseMail(_ decision: OnboardingRules.MailDecision) {
        guide.mailDecision = decision.rawValue
        switch decision {
        case .configured: mailStep = .routes
        case .dragOnly: mailStep = .senders
        case .skipped: advance()
        }
    }

    func chooseRoute(_ r: OnboardingRules.MailRoute) {
        mailRoute = r
        m365Answer = nil
        mailStep = r == .m365 ? .m365 : .guide
    }

    func answerM365(_ a: OnboardingRules.M365Answer) {
        m365Answer = a
        mailStep = .guide
    }

    var routeTarget: OnboardingRules.RouteTarget? {
        mailRoute.map { OnboardingRules.target($0, m365: m365Answer) }
    }

    /// An account was saved in the sheet: the senders step.
    func mailSheetClosed() {
        mailSheet = nil
        if !settings.mailAccounts.isEmpty {
            guide.mailDecision = OnboardingRules.MailDecision.configured.rawValue
            mailStep = .senders
        }
    }

    /// Adds an advisor / colleague (the organization's people default: ask or never — never always).
    @discardableResult
    func addAdvisor() -> Bool {
        let address = advisorAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.count <= 254,
              !settings.mailSenders.contains(where: { $0.pattern.caseInsensitiveCompare(address) == .orderedSame }) else { return false }
        let policy = settings.config.snapshot.organization.peopleDefault.policy
        settings.mailSenders.append(SenderRule(pattern: address, label: "", kind: .advisor, aiPolicy: policy))
        advisorAddress = ""
        senderAdded = true
        return true
    }

    /// The field's suggested alert presets: on = in the sender list (they start off).
    func presetEnabled(_ id: String) -> Bool { settings.mailSenders.contains { $0.id == id } }

    func setPreset(_ rule: SenderRule, on: Bool) {
        if on, !presetEnabled(rule.id) { settings.mailSenders.append(rule) }
        if !on { settings.mailSenders.removeAll { $0.id == rule.id } }
    }

    var canTurnOnMail: Bool { OnboardingRules.canTurnOnMail(facts.facts.mail.accounts) && !settings.mailEnabled }

    func turnOnMail() {
        guard canTurnOnMail else { return }
        settings.mailEnabled = true
        guide.mailDecision = OnboardingRules.MailDecision.configured.rawValue
    }

    // MARK: Finish (P8)

    var canFinish: Bool {
        let usable = GuideEvaluator.evaluate(.libraryUsable, facts.facts) == .done || state != nil
        return OnboardingRules.canFinish(libraryUsable: usable, aiDecided: aiDecided)
    }

    func finish(_ choice: FinishChoice) {
        if mode == .live {
            guard canFinish else { return }
            settings.setupCompleted = true
            guide.markOnboardingFinished(showChecklist: showChecklistOnToday)
        }
        onFinish?(choice)
    }
}

/// The library commit's file-system step (off the main actor).
nonisolated enum LibraryCommit {
    enum Outcome: Sendable, Equatable { case ok, denied, missingParent, readOnly }

    /// `create`: a new library (the folder is made if needed — inside Documents this is when
    /// macOS asks for access). An existing library must already be there.
    static func prepare(_ target: URL, create: Bool) async -> Outcome {
        await BlockingIO.run { check(target, create: create) }
    }

    static func check(_ target: URL, create: Bool) -> Outcome {
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            guard create else { return .missingParent }
            switch LibraryPaths.status(of: target.deletingLastPathComponent()) {
            case .denied: return .denied
            case .missing: return .missingParent
            case .readOnly: return .readOnly
            case .ok, .ubiquitous: break
            }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                return FileOps.classify(error) == .permissionDenied ? .denied : .readOnly
            }
        }
        switch LibraryPaths.status(of: target) {
        case .ok, .ubiquitous: return .ok
        case .denied: return .denied
        case .missing: return .missingParent
        case .readOnly: return .readOnly
        }
    }
}
