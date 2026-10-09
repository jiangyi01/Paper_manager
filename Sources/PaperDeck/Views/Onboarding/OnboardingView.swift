import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The setup window: header with the language switch, the step rail, the page, and the footer
/// ((?) Help · Back · Skip · Continue).
struct OnboardingView: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                rail
                    .frame(width: 190)
                    .background(.background.secondary)
                Divider()
                ScrollView {
                    page
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { model.facts.activate("onboarding") }
        .onDisappear { model.facts.deactivate("onboarding") }
        .alert(L.Onb.continueWithoutAITitle, isPresented: Binding(get: { model.askContinueWithoutAI },
                                                                  set: { model.askContinueWithoutAI = $0 })) {
            Button(L.Onb.continueWithoutAI) { model.continueWithoutAI() }
            Button(L.Onb.turnOnEllipsis) { model.turnOnAndContinue() }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Onb.continueWithoutAIBody(model.aiChoice?.provider ?? .claude))
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var settings = model.settings
        return HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            Text(model.mode == .revisit ? L.Onb.revisitTitle : L.Onb.windowTitle).font(.headline)
            Spacer()
            if settings.language == .en, Locale.preferredLanguages.first?.hasPrefix("zh") == true {
                Button(L.Onb.switchToChinese) { settings.language = .zh }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Picker("", selection: $settings.language) {
                Text("English").tag(UILang.en)
                Text("中文").tag(UILang.zh)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(L.language)
        }
        .padding(.leading, 78)       // the traffic lights (transparent title bar)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(OnboardingPage.allCases, id: \.self) { p in
                let current = p == model.page
                let state = model.railState(p)
                Button {
                    model.go(p)
                } label: {
                    HStack(spacing: 8) {
                        RailMark(current: current, state: state)
                        Text(L.Onb.page(p))
                            .font(.callout.weight(current ? .semibold : .regular))
                            .foregroundStyle(model.pages.contains(p) ? .primary : .tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canJump(to: p) || current || model.committing)
                .accessibilityLabel("\(L.Onb.page(p)), \(current ? L.Onb.stepCurrent : RailMark.label(state))")
            }
            Spacer()
        }
        .padding(10)
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        switch model.page {
        case .welcome: WelcomePage(model: model)
        case .about: AboutPage(model: model)
        case .ai: AIPage(model: model)
        case .library: LibraryPage(model: model)
        case .plan: PlanPage(model: model)
        case .mail: MailPage(model: model)
        case .importPapers: ImportPage(model: model)
        case .finish: FinishPage(model: model)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                HelpCenter.openTopic(model.page.helpTopic)
            } label: {
                Label(L.Onb.help, systemImage: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            if model.committing {
                ProgressView().controlSize(.small)
                Text(L.Onb.opening).foregroundStyle(.secondary)
            } else if model.page == .finish && !model.canFinish {
                NoteText(L.Onb.finishNeeds, symbol: "info.circle")
            }
            Spacer()
            if model.canGoBack {
                Button(L.Onb.back) { model.back() }
                    .keyboardShortcut("[", modifiers: .command)
            }
            if model.isOptional {
                Button(L.Onb.skip) { model.skip() }
            }
            if model.page == .finish {
                Button(model.mode == .revisit ? L.Onb.done : L.Onb.finish) { model.finish(.close) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.mode == .live && !model.canFinish)
            } else if model.page != .welcome || model.mode != .preflight {
                Button(L.Onb.continueButton) { model.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.committing || !canContinue)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var canContinue: Bool {
        switch model.page {
        case .library where model.mode == .preflight:
            if case .existing = model.libraryChoice { return OnboardingModel.isExistingLibrary(model.inspected) }
            return true
        default:
            return true
        }
    }
}

/// ✓ done / ● current / ○ to do / – skipped / ⚠ problem.
private struct RailMark: View {
    let current: Bool
    let state: CheckState

    var body: some View {
        Group {
            if current {
                Image(systemName: "circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 9))
            } else {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .notApplicable: Image(systemName: "minus").foregroundStyle(.secondary)
                case .todo, .unknown: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 16)
    }

    static func label(_ s: CheckState) -> String {
        switch s {
        case .done: L.Onb.stepDone
        case .problem: L.Onb.stepProblem
        case .notApplicable: L.Onb.stepSkipped
        case .todo, .unknown: L.Onb.stepTodo
        }
    }
}

/// A page's title and subtitle.
struct OnboardingHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 6)
    }
}

/// A selectable option card (AI providers, library choices).
struct ChoiceCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
