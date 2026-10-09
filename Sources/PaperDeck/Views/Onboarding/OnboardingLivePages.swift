import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

// P5–P8: Daily plan, Mail, Import, Finish (the engine is open).

// MARK: - P5 Daily plan & reminder

struct PlanPage: View {
    let model: OnboardingModel

    var body: some View {
        let f = model.facts.facts
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(title: L.Onb.planTitle, subtitle: L.Onb.planSubtitle)
            VStack(alignment: .leading, spacing: 10) {
                BudgetPicker(settings: model.settings).fixedSize()
                WeekdayPicker(settings: model.settings)
                ReminderTimePicker(settings: model.settings).fixedSize()
            }
            notifications(f)
            login(f)
            if case .problem(let why) = GuideEvaluator.evaluate(.appInApplications, f) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusLine(.warning, L.Onb.moveToApplications)
                    Text(why(L.lang)).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(L.Onb.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        Button(L.quit) { NSApp.terminate(nil) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func notifications(_ f: SetupFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.Onb.notificationsTitle).font(.headline)
            NoteText(L.Pref.notificationsWhy)
            HStack(spacing: 10) {
                switch f.notifications.known?.authorization {
                case .authorized?, .provisional?:
                    StatusLine(.ok, L.Onb.notificationsAllowed)
                case .denied?:
                    StatusLine(.warning, L.Onb.notificationsDenied)
                    Button(L.Onb.openNotificationSettings) { ReminderService.openSystemNotificationSettings() }
                case .notDetermined?:
                    StatusLine(.pending, L.Onb.notificationsUnknown)
                    Button(L.Onb.allowNotifications) {
                        Task {
                            _ = await ReminderService.shared?.requestAuthorization()
                            model.facts.kick()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                case .unavailable?:
                    StatusLine(.neutral, L.Onb.notificationsUnavailable)
                case nil:
                    StatusLine(.working, L.Onb.checking)
                }
            }
            .controlSize(.small)
        }
    }

    private func login(_ f: SetupFacts) -> some View {
        let status = f.loginItem.known?.status
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(L.Onb.loginToggle, isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { on in
                    LaunchAtLogin.set(on, settings: model.settings)
                    model.facts.kick()
                }))
                .disabled(status == .notFound)
            NoteText(L.Onb.loginHint)
            if status == .requiresApproval {
                HStack {
                    StatusLine(.warning, L.Onb.loginNeedsApproval)
                    Button(L.Onb.openLoginItems) {
                        SystemLinks.open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - P6 Mail (optional)

struct MailPage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.mailStep {
            case .ask: ask
            case .routes: routes
            case .m365: m365
            case .guide: guide
            case .senders: senders
            }
        }
        .sheet(item: Binding(get: { model.mailSheet.map(MailRouteSheet.init) }, set: { model.mailSheet = $0?.source })) { item in
            if let state = model.state {
                MailAddAccountSheet(state: state, editing: nil, initialTemplate: MailAccountTemplate(source: item.source),
                                    onClose: { model.mailSheetClosed() })
            }
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeader(title: L.Onb.mailAskTitle, subtitle: L.Onb.mailAskBody)
            HStack(spacing: 10) {
                Button(L.Onb.setUpNow) { model.chooseMail(.configured) }.buttonStyle(.borderedProminent)
                Button(L.Onb.dragOnly) { model.chooseMail(.dragOnly) }
                Button(L.Onb.notNow) { model.chooseMail(.skipped) }
            }
            .controlSize(.large)
            if model.guide.mailDecision == OnboardingRules.MailDecision.dragOnly.rawValue {
                NoteText(L.Onb.dragTip, symbol: "hand.draw")
            }
        }
    }

    private var routes: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnboardingHeader(title: L.Onb.whereTitle)
            ForEach(OnboardingRules.MailRoute.allCases, id: \.self) { r in
                Button { model.chooseRoute(r) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: L.Onb.routeSymbol(r)).frame(width: 22).foregroundStyle(.tint)
                        Text(L.Onb.route(r)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            NoteText(L.Onb.dragTip, symbol: "hand.draw")
        }
    }

    private var m365: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeader(title: L.Onb.m365Title)
            HStack(spacing: 10) {
                Button(L.Onb.m365Yes) { model.answerM365(.yes) }.buttonStyle(.borderedProminent)
                Button(L.Onb.m365Unsure) { model.answerM365(.unsure) }
                Button(L.Onb.m365Blocked) { model.answerM365(.blocked) }
            }
            .controlSize(.large)
            Button(L.Onb.otherRoutes) { model.mailStep = .routes }.buttonStyle(.link)
        }
    }

    @ViewBuilder private var guide: some View {
        if let route = model.mailRoute, let target = model.routeTarget {
            let runner = GuideActionRunner(settings: model.settings, state: model.state,
                                           openTopic: { HelpCenter.openTopic($0) },
                                           openMailSheet: { model.mailSheet = $0 })
            OnboardingHeader(title: L.Onb.route(route))
            if let source = target.source {
                Button(L.Onb.addAccount) { model.mailSheet = source }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state == nil)
            }
            if let topic = GuideCatalog.topic(target.topic) {
                TutorialView(topic: topic, facts: model.facts, runner: runner, compact: true)
            } else {
                NoteText(L.Onb.guidePending, symbol: "book")
            }
            HStack {
                Button(L.Onb.openGuide) { HelpCenter.openTopic(target.topic) }
                Button(L.Onb.otherRoutes) { model.mailStep = .routes }.buttonStyle(.link)
                if !model.settings.mailAccounts.isEmpty {
                    Button(L.Onb.sendersTitle) { model.mailStep = .senders }.buttonStyle(.link)
                }
            }
            turnOn
        }
    }

    private var senders: some View {
        let config = model.settings.config.snapshot
        let field = config.field
        return VStack(alignment: .leading, spacing: 12) {
            OnboardingHeader(title: L.Onb.sendersTitle)
            if model.guide.mailDecision == OnboardingRules.MailDecision.dragOnly.rawValue {
                NoteText(L.Onb.dragTip, symbol: "hand.draw")
            }
            HStack {
                TextField(L.Onb.advisorPlaceholder, text: Binding(get: { model.advisorAddress }, set: { model.advisorAddress = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { model.addAdvisor() }
                Button(L.Onb.addSender) { model.addAdvisor() }
                    .disabled(!model.advisorAddress.contains("@"))
                if model.senderAdded { StatusLine(.ok, L.Onb.addedSender) }
            }
            Text(OrgStrings.text(.personSenderWarning, org: config.organization, lang: L.lang))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.Onb.suggestedFor(field.name(L.lang))).font(.headline).padding(.top, 6)
            ForEach(SenderPresetCatalog.suggested(for: field), id: \.id) { rule in
                Toggle(isOn: Binding(get: { model.presetEnabled(rule.id) }, set: { model.setPreset(rule, on: $0) })) {
                    HStack {
                        Text(rule.label)
                        Text(rule.pattern).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            NoteText(L.Onb.presetNote, symbol: "sparkles")
            turnOn
        }
    }

    /// [Turn On Mail] — only once an account was saved (and isn't waiting for setup).
    @ViewBuilder private var turnOn: some View {
        if !model.settings.mailAccounts.isEmpty {
            HStack(spacing: 10) {
                if model.settings.mailEnabled {
                    StatusLine(.ok, L.Onb.mailIsOn)
                    Text(syncLine).foregroundStyle(.secondary)
                } else {
                    Button(L.Onb.turnOnMail) { model.turnOnMail() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canTurnOnMail)
                }
            }
            .padding(.top, 6)
        }
    }

    private var syncLine: String {
        let infos = model.state?.mailSnapshot?.accounts ?? []
        guard let last = infos.compactMap(\.lastSuccessAt).max() else { return L.Onb.notSyncedYet }
        return L.Onb.synced(L.Mail.ago(last), infos.reduce(0) { $0 + $1.totalCaptured })
    }
}

private struct MailRouteSheet: Identifiable {
    let source: MailSourceID
    var id: String { source.rawValue }
}

// MARK: - P7 Import (optional)

struct ImportPage: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeader(title: L.Onb.importTitle, subtitle: L.Onb.importHint)
            if let state = model.state {
                SetupImportStep(state: state, startFolder: SetupImportStep.defaultFolder(model.settings), number: nil)
            }
        }
    }
}

// MARK: - P8 Finish

struct FinishPage: View {
    let model: OnboardingModel

    var body: some View {
        let f = model.facts.facts
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(title: L.Onb.finishTitle)
            VStack(alignment: .leading, spacing: 8) {
                line(GuideEvaluator.evaluate(.libraryUsable, f),
                     L.Onb.libraryLine(f.library.known?.tildePath ?? SettingsFormat.tildePath(model.settings.libraryPath),
                                       f.papers.known?.live ?? 0), page: .library)
                line(aiState(f), aiText(f), page: .ai)
                line(model.settings.reminderEnabled ? GuideEvaluator.evaluate(.notificationsAllowed, f) : .notApplicable,
                     reminderText(f), page: .plan)
                line(mailState(f), mailText(f), page: .mail)
                if let signing = signingText(f) {
                    line(GuideEvaluator.evaluate(.stableSigning, f), signing, page: nil)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Onb.findHere).font(.headline)
                Label(L.Onb.findMenuBar, systemImage: "menubar.rectangle")
                Label(L.Onb.findStrip, systemImage: "rectangle.righthalf.inset.filled")
                Label(L.Onb.findHelp, systemImage: "questionmark.circle")
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(L.Onb.takeTour) { model.finish(.tour) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.mode == .live && !model.canFinish)
                Button(L.Onb.openLibrary) { model.finish(.library) }
                    .disabled(model.mode == .live && !model.canFinish)
            }
            .controlSize(.large)
            if f.profile.origin == .fresh {
                Toggle(L.Onb.showChecklist, isOn: Binding(get: { model.showChecklistOnToday },
                                                          set: { model.showChecklistOnToday = $0 }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func line(_ state: CheckState, _ text: String, page: OnboardingPage?) -> some View {
        HStack(spacing: 8) {
            CheckStateIcon(state: state)
            Text(text)
            if let page, model.canJump(to: page) || model.mode == .revisit {
                Button(L.Onb.change) { model.go(page) }.buttonStyle(.link)
            }
        }
    }

    private func aiState(_ f: SetupFacts) -> CheckState {
        model.aiDecided ? (f.ai.mode.providerKind != nil ? GuideEvaluator.evaluate(.aiReady, f) : .notApplicable) : .todo
    }

    private func aiText(_ f: SetupFacts) -> String {
        guard let k = f.ai.mode.providerKind else { return L.Onb.aiNotNow }
        if case .ready(let plan, _, _)? = f.ai.statuses[k]?.known { return L.Onb.aiLine(k, plan: SettingsFormat.plan(plan)) }
        return L.Onb.aiLine(k, plan: nil)
    }

    private func reminderText(_ f: SetupFacts) -> String {
        guard model.settings.reminderEnabled else { return L.Onb.reminderOff }
        let time = String(format: "%02d:%02d", model.settings.reminderHour, model.settings.reminderMinute)
        return L.Onb.reminderLine(time, allowed: GuideEvaluator.evaluate(.notificationsAllowed, f) == .done)
    }

    private func mailState(_ f: SetupFacts) -> CheckState {
        f.mail.accounts.isEmpty ? .notApplicable : GuideEvaluator.evaluate(.mailAccountReady(nil), f)
    }

    private func mailText(_ f: SetupFacts) -> String {
        if !f.mail.accounts.isEmpty { return L.Onb.mailLine(f.mail.accounts.count, on: f.mail.enabled) }
        return model.guide.mailDecision == OnboardingRules.MailDecision.dragOnly.rawValue ? L.Onb.mailDragOnly : L.Onb.mailNotSetUp
    }

    /// Local builds only (a distributed app never mentions certificates).
    private func signingText(_ f: SetupFacts) -> String? {
        guard BuildIdentity.current.channel == .local, let s = f.signing.known else { return nil }
        switch s.kind {
        case .certificate(let name): return L.Onb.signingLine(name)
        case .adhoc, .unsigned: return L.Onb.signingAdhoc
        }
    }
}
