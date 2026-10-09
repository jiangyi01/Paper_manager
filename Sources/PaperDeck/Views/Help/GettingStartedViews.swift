import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The live checklist rows for this Mac (`GettingStarted.items`).
@MainActor
enum GettingStartedRows {
    static func items(_ facts: SetupFactsCollector) -> [GettingStarted.Item] {
        GettingStarted.items(facts.facts, skipped: facts.guide.skipped, mailDecision: facts.guide.mailDecision,
                             manualDone: facts.guide.manualDone)
    }

    /// The buttons of a row (the first is the main one).
    static func actions(_ id: String, state: CheckState, runner: GuideActionRunner, facts: SetupFactsCollector)
        -> [(title: String, run: () -> Void)] {
        let settings = runner.settings
        let router = runner.state?.router
        var out: [(String, () -> Void)] = []
        switch id {
        case GettingStarted.library:
            out.append((L.Help.librarySettings, { router?.showSettings("library") }))
        case GettingStarted.firstPaper:
            out.append((L.Help.addPDF, { router?.pickAndImportFiles() }))
            out.append((L.Help.showDropStrip, { router?.armDropPanel(10) }))
        case GettingStarted.dropStrip:
            out.append((L.Help.showMe, { router?.armDropPanel(10) }))
        case GettingStarted.openCard:
            out.append((L.Help.openToday, { router?.showToday() }))
        case GettingStarted.ai:
            out.append((L.Help.aiSettings, { router?.showSettings("ai") }))
        case GettingStarted.reminder:
            if case .problem = state {
                out.append((L.Help.openNotificationSettings, { ReminderService.openSystemNotificationSettings() }))
            } else {
                out.append((L.Help.allow, {
                    Task {
                        _ = await ReminderService.shared?.requestAuthorization()
                        facts.kick()
                    }
                }))
            }
        case GettingStarted.login:
            out.append((L.Help.openAtLogin, {
                LaunchAtLogin.set(true, settings: settings)
                facts.kick()
            }))
        case GettingStarted.widget:
            out.append((L.Help.widgetSettings, { router?.showSettings("widget") }))
            if facts.facts.widget.known?.placedCount == nil, state != .done {
                out.append((L.Help.iveAddedIt, { facts.guide.toggleManual(GettingStarted.widgetManualKey) }))
            }
        case GettingStarted.mail:
            out.append((state == .notApplicable ? L.Help.setUp : L.Help.connectMail, { runner.openTopic(.connectMail) }))
        case GettingStarted.senders:
            out.append((L.Help.senderList, { router?.showSettings("mail") }))
        case GettingStarted.backup:
            out.append((L.Help.exportSettings, { router?.showSettings("general") }))
        default:
            break
        }
        return out.map { (title: $0.0, run: $0.1) }
    }
}

/// Help Center ▸ Getting Started.
struct GettingStartedView: View {
    let facts: SetupFactsCollector
    let runner: GuideActionRunner

    var body: some View {
        let items = GettingStartedRows.items(facts)
        let progress = GettingStarted.progress(items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.Help.gettingStarted).font(.title2.weight(.semibold))
                Spacer()
                Text(L.Help.progress(progress.done, progress.total)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(L.Help.gettingStartedSubtitle).foregroundStyle(.secondary)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            VStack(spacing: 0) {
                ForEach(items.filter(\.visible), id: \.id) { item in
                    GettingStartedRow(item: item, facts: facts, runner: runner, showSkip: true)
                    Divider()
                }
            }
            if !facts.guide.skipped.isEmpty {
                Button(L.Help.showSkipped) { facts.guide.skipped = [] }.buttonStyle(.link)
            }
            Toggle(L.Help.showChecklist, isOn: Binding(get: { !facts.guide.checklistDismissed },
                                                       set: { facts.guide.checklistDismissed = !$0 }))
                .toggleStyle(.checkbox)
                .disabled(facts.facts.profile.origin != .fresh)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One checklist row.
struct GettingStartedRow: View {
    let item: GettingStarted.Item
    let facts: SetupFactsCollector
    let runner: GuideActionRunner
    var showSkip = false
    var compact = false

    var body: some View {
        let lang = L.lang
        HStack(alignment: .center, spacing: 10) {
            CheckStateIcon(state: item.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.id == GettingStarted.mail && item.state == .notApplicable
                         ? L.Help.notUsingMail : GettingStarted.title(item.id)(lang))
                        .font(compact ? .callout : .body)
                        .strikethrough(item.state == .done && compact, color: .secondary)
                    if item.required && !compact {
                        Text(L.Help.required).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                if case .problem(let why) = item.state {
                    Text(why(lang)).font(.caption).foregroundStyle(.orange).lineLimit(compact ? 1 : 3)
                } else if item.id == GettingStarted.library, item.state == .done,
                          facts.facts.library.known?.volume == .cloud {
                    Text(L.Help.cloudLibraryNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.state != .done {
                let actions = GettingStartedRows.actions(item.id, state: item.state, runner: runner, facts: facts)
                ForEach(Array(actions.prefix(compact ? 1 : 2).enumerated()), id: \.offset) { _, a in
                    Button(a.title, action: a.run).controlSize(.small).disabled(runner.state == nil)
                }
                if showSkip, !item.required {
                    Button(L.Help.skipThis) { facts.guide.skipped.insert(item.id) }
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                }
                if !compact, let topic = GettingStarted.topic(item.id) {
                    Button { runner.openTopic(topic) } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .help(GuideCatalog.topic(topic)?.title(lang) ?? L.Help.learnMore)
                }
            }
        }
        .padding(.vertical, compact ? 4 : 8)
    }
}

/// The compact card above Today (and in the empty library), fresh installs only.
struct GettingStartedCard: View {
    let facts: SetupFactsCollector
    let runner: GuideActionRunner

    /// Decided before any fact is composed: a legacy install (or a dismissed card) returns at
    /// once, so its Today, empty library and menu-bar menu never compose — nor observe — the
    /// library, mail and guide facts on every render.
    static func isShown(_ facts: SetupFactsCollector) -> Bool {
        guard facts.origin == .fresh, !facts.guide.checklistDismissed else { return false }
        return GettingStarted.showOnToday(origin: .fresh, dismissed: false, items: GettingStartedRows.items(facts))
    }

    var body: some View {
        let items = GettingStartedRows.items(facts)
        let progress = GettingStarted.progress(items)
        let pending = items.filter { $0.visible && $0.state != .done && $0.state != .notApplicable }
        let open = pending.filter(\.required) + pending.filter { !$0.required }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L.Help.cardTitle, systemImage: "checklist").font(.headline)
                Text(L.Help.progress(progress.done, progress.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(L.Help.openChecklist) { runner.openTopic(.gettingStarted) }.controlSize(.small)
                Button(L.Help.hide) { facts.guide.checklistDismissed = true }
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
            ForEach(open.prefix(3), id: \.id) { item in
                GettingStartedRow(item: item, facts: facts, runner: runner, compact: true)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
        // One refresh when it appears (no periodic probing, no CLI): the card is on Today all day.
        .task { await facts.refreshOnce() }
    }
}
