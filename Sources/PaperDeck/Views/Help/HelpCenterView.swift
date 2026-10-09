import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// What the Help Center shows.
enum HelpSection: Hashable {
    case gettingStarted, tour, troubleshooting, diagnostics
    case topic(GuideTopicID)
}

/// The Help Center's navigation (one per window).
@Observable
final class HelpCenterModel {
    /// A navigation-only id (`paperdeck://help/troubleshooting`): the troubleshooting list.
    static let troubleshootingID: GuideTopicID = "troubleshooting"

    var section: HelpSection? = .gettingStarted
    var query = ""
    /// The add-account sheet a tutorial asked for.
    var mailSheet: MailSourceID?

    /// A topic id (or a section id) → its page.
    func open(_ id: GuideTopicID?) {
        query = ""
        guard let id else { section = .gettingStarted; return }
        switch id {
        case .gettingStarted: section = .gettingStarted
        case .tour: section = .tour
        case .diagnostics: section = .diagnostics
        case Self.troubleshootingID: section = .troubleshooting
        // A topic the catalog doesn't have (an old link) lands on Getting Started.
        default: section = GuideCatalog.topic(id) != nil ? .topic(id) : .gettingStarted
        }
    }
}

/// Help ▸ PaperDeck Help (⌘?): a sidebar of sections and topics, search, and the page.
struct HelpCenterView: View {
    let model: HelpCenterModel
    let facts: SetupFactsCollector
    let settings: SettingsStore

    var body: some View {
        @Bindable var model = model
        let runner = GuideActionRunner(settings: settings, state: facts.state,
                                       openTopic: { model.open($0) },
                                       openMailSheet: facts.state == nil ? nil : { model.mailSheet = $0 })
        NavigationSplitView {
            sidebar(runner)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            ScrollView {
                detail(runner)
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: L.Help.searchPrompt)
        .onAppear { facts.activate("help-center") }
        .onDisappear { facts.deactivate("help-center") }
        .sheet(item: Binding(get: { model.mailSheet.map(MailSheetItem.init) }, set: { model.mailSheet = $0?.source })) { item in
            if let state = facts.state {
                MailAddAccountSheet(state: state, editing: nil, initialTemplate: MailAccountTemplate(source: item.source),
                                    onClose: { model.mailSheet = nil })
            }
        }
    }

    // MARK: Sidebar

    @ViewBuilder private func sidebar(_ runner: GuideActionRunner) -> some View {
        @Bindable var model = model
        let lang = L.lang
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = GuideSearch.search(model.query, lang: lang).compactMap(GuideCatalog.topic)
            List(selection: $model.section) {
                if hits.isEmpty {
                    Text(L.Help.noResults).foregroundStyle(.secondary)
                }
                ForEach(hits) { t in
                    Label(t.title(lang), systemImage: Self.symbol(t.kind)).tag(HelpSection.topic(t.id))
                }
            }
        } else {
            let topics = GuideCatalog.topics
            let items = GettingStartedRows.items(facts)
            let progress = GettingStarted.progress(items)
            List(selection: $model.section) {
                Label {
                    HStack {
                        Text(L.Help.gettingStarted)
                        Spacer()
                        Text(L.Help.progress(progress.done, progress.total)).foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "checklist") }
                .tag(HelpSection.gettingStarted)
                Label(L.Help.tour, systemImage: "play.rectangle").tag(HelpSection.tour)
                let mail = topics.filter { $0.id.rawValue.hasPrefix("mail-") || $0.id == .connectMail }
                if !mail.isEmpty {
                    Section(L.Help.mailTutorials) {
                        ForEach(mail) { t in Label(t.title(lang), systemImage: "envelope").tag(HelpSection.topic(t.id)) }
                    }
                }
                let others = topics.filter { t in
                    (t.kind == .tutorial || t.kind == .reference) && !mail.contains(where: { $0.id == t.id })
                        && ![GuideTopicID.gettingStarted, .tour, .diagnostics].contains(t.id)
                }
                if !others.isEmpty {
                    Section(L.Help.tutorials) {
                        ForEach(others) { t in Label(t.title(lang), systemImage: Self.symbol(t.kind)).tag(HelpSection.topic(t.id)) }
                    }
                }
                Section {
                    Label {
                        HStack {
                            Text(L.Help.troubleshooting)
                            let n = topics.filter { GuideEvaluator.appliesNow($0, facts.facts) }.count
                            if n > 0 {
                                Spacer()
                                Text("\(n)").font(.caption.weight(.bold)).padding(.horizontal, 6)
                                    .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                            }
                        }
                    } icon: { Image(systemName: "wrench.and.screwdriver") }
                    .tag(HelpSection.troubleshooting)
                    Label(L.Help.diagnostics, systemImage: "stethoscope").tag(HelpSection.diagnostics)
                }
            }
        }
    }

    static func symbol(_ k: GuideKind) -> String {
        switch k {
        case .checklist: "checklist"
        case .tour: "play.rectangle"
        case .tutorial: "book"
        case .troubleshoot: "wrench.and.screwdriver"
        case .reference: "doc.text"
        }
    }

    // MARK: Page

    @ViewBuilder private func detail(_ runner: GuideActionRunner) -> some View {
        switch model.section ?? .gettingStarted {
        case .gettingStarted:
            GettingStartedView(facts: facts, runner: runner)
        case .tour:
            TourView(facts: facts, runner: runner, onDone: { model.open(.gettingStarted) })
        case .troubleshooting:
            TroubleshootingList(facts: facts, runner: runner)
        case .diagnostics:
            DiagnosticsView(facts: facts, settings: settings)
        case .topic(let id):
            if let t = GuideCatalog.topic(id) {
                TutorialView(topic: t, facts: facts, runner: runner)
            } else {
                Text(L.Help.topicUnavailable).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MailSheetItem: Identifiable {
    let source: MailSourceID
    var id: String { source.rawValue }
}

/// Help ▸ Troubleshooting: every entry, those that apply now first.
struct TroubleshootingList: View {
    let facts: SetupFactsCollector
    let runner: GuideActionRunner
    /// nil: the catalog's troubleshooting entries.
    var topics: [GuideTopic]? = nil

    var body: some View {
        let lang = L.lang
        let f = facts.facts
        let entries = topics ?? GuideCatalog.topics.filter { $0.kind == .troubleshoot }
        let sorted = entries.filter { GuideEvaluator.appliesNow($0, f) } + entries.filter { !GuideEvaluator.appliesNow($0, f) }
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Help.troubleshooting).font(.title2.weight(.semibold))
            Text(L.Help.troubleshootingSubtitle).foregroundStyle(.secondary)
            if sorted.isEmpty { Text(L.Help.topicUnavailable).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(sorted) { t in
                    Button { runner.openTopic(t.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title(lang)).foregroundStyle(.primary)
                                if !t.summary(lang).isEmpty {
                                    Text(t.summary(lang)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            if GuideEvaluator.appliesNow(t, f) { AppliesNowBadge() }
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

/// Help ▸ Diagnostics: what PaperDeck sees on this Mac, and a redacted text to copy.
///
/// The rows are worded for people (`DiagnosticsRows`, en + zh); the raw values (`notDetermined`,
/// `registered`, `generic`…) appear only in the copied `DiagnosticsReport` text.
struct DiagnosticsView: View {
    let facts: SetupFactsCollector
    let settings: SettingsStore
    @State private var preview: String?

    var body: some View {
        let rows = DiagnosticsRows.rows(facts.facts, config: settings.config.snapshot)
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Help.diagnostics).font(.title2.weight(.semibold))
            Text(L.Help.diagnosticsSubtitle).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    if let state = r.state {
                        row(r.title, state, r.detail)
                    } else {
                        GridRow {
                            Image(systemName: "building.columns").foregroundStyle(.secondary).frame(width: 18)
                            Text(r.title)
                            Text(r.detail).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button(L.Help.copyDiagnostics) { preview = report }
                Button(L.Help.refresh) { facts.kick(providers: true) }
            }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            DiagnosticsPreview(text: preview ?? "", onClose: { preview = nil })
        }
        // Both providers' status belongs in the report (zero quota; throttled).
        .task { facts.kick(providers: true) }
    }

    private var report: String {
        DiagnosticsReport.render(facts.facts, identity: BuildIdentity.current, config: settings.config.snapshot,
                                 appVersion: CLIRunner.versionString, home: SharedPaths.realHome.path, redact: true)
    }

    private func row(_ title: String, _ state: CheckState, _ detail: String) -> some View {
        GridRow {
            CheckStateIcon(state: state)
            Text(title)
            Group {
                if case .problem(let why) = state { Text(why(L.lang)).foregroundStyle(.orange) }
                else { Text(detail).foregroundStyle(.secondary) }
            }
            .lineLimit(2)
        }
    }
}

/// The Diagnostics page's rows, worded in the UI language (pure; `--selftest onboarding` checks
/// that no raw value leaks into them).
enum DiagnosticsRows {
    struct Row: Equatable {
        var title: String
        /// nil: an information row (the configuration line).
        var state: CheckState?
        var detail: String
    }

    static func rows(_ f: SetupFacts, config c: ConfigSnapshot) -> [Row] {
        [
            Row(title: L.Help.dLibrary, state: GuideEvaluator.evaluate(.libraryUsable, f), detail: f.library.known?.tildePath ?? ""),
            Row(title: L.Help.dPapers, state: GuideEvaluator.evaluate(.hasPapers(1), f), detail: f.papers.known.map { "\($0.live)" } ?? ""),
            Row(title: L.Help.dAI, state: GuideEvaluator.evaluate(.aiDecided, f), detail: L.Help.dAIDetail(f.ai.mode, f.ai.provider)),
            Row(title: L.Help.dNotifications, state: GuideEvaluator.evaluate(.notificationsAllowed, f),
                detail: f.notifications.known.map { L.Help.dNotificationsDetail($0.authorization) } ?? ""),
            Row(title: L.Help.dLogin, state: GuideEvaluator.evaluate(.launchAtLogin, f),
                detail: f.loginItem.known.map { L.Help.dLoginDetail($0.status) } ?? ""),
            Row(title: L.Help.dWidget, state: GuideEvaluator.evaluate(.widgetRegistered, f),
                detail: f.widget.known.map { L.Help.dWidgetDetail($0.registration) } ?? ""),
            Row(title: L.Help.dApp, state: GuideEvaluator.evaluate(.appInApplications, f),
                detail: f.app.known.map { L.Help.dAppDetail($0.location) } ?? ""),
            Row(title: L.Help.dSigning, state: GuideEvaluator.evaluate(.stableSigning, f),
                detail: f.signing.known.map { L.Help.dSigningDetail($0.kind) } ?? ""),
            Row(title: L.Help.dMail, state: mailState(f), detail: L.Help.dMailDetail(enabled: f.mail.enabled, accounts: f.mail.accounts.count)),
            Row(title: L.Help.dConfig, state: nil, detail: configLine(c)),
        ]
    }

    /// A failed sign-in or files that aren't emails come first; then whether any account works.
    static func mailState(_ f: SetupFacts) -> CheckState {
        guard !f.mail.accounts.isEmpty else { return .notApplicable }
        for check in [GuideCheck.mailAccountAuthFailed, .mailNoNotEmailFiles] {
            if case .problem = GuideEvaluator.evaluate(check, f) { return GuideEvaluator.evaluate(check, f) }
        }
        return GuideEvaluator.evaluate(.mailAccountReady(nil), f)
    }

    /// "<short name> · <field> · <stage>"; an institution without a name (the generic preset)
    /// reads "No specific institution" rather than its id.
    static func configLine(_ c: ConfigSnapshot) -> String {
        let org = c.organization
        let name = org.shortName.flatMap { $0.isEmpty ? nil : $0 } ?? org.name.map { $0(L.lang) } ?? L.Help.dNoInstitution
        return "\(name) · \(c.field.name(L.lang)) · \(c.stage.title(L.lang))"
    }
}

/// The redacted diagnostics text the user copies (shown before anything is copied).
struct DiagnosticsPreview: View {
    let text: String
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Help.diagnosticsPreview).font(.headline)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button(L.Help.close, action: onClose).keyboardShortcut(.cancelAction)
                Button(copied ? L.Help.copied : L.Help.copy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
    }
}
