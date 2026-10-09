import SwiftUI
import PaperDeckCore

/// The notice under the last question when it got no (full) answer (`AskNotice`): what happened and
/// the one action that helps. Actions that send again go through `perform` (a fresh click, a fresh
/// ticket minted by the hosting view); nothing retries on its own.
struct AskNoticeView: View {
    let state: AppState
    let session: AskSession
    let notice: AskNotice
    let perform: (AskIntent) -> Void

    var body: some View {
        if notice == .off {
            AskEnableCard(state: state) { session.notice = nil }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { session.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(L.QA.dismiss)
                        .accessibilityLabel(L.QA.dismiss)
                }
                buttons
            }
            .padding(10)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.22)))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            switch notice {
            case .confirm:
                Button(L.cancel) { session.notice = nil }
                Button(L.QA.confirmSend) { perform(.confirmPrivacy) }.buttonStyle(.borderedProminent)
            case .softCap:
                Button(L.QA.continueAnyway) { perform(.continuePastCap) }.buttonStyle(.borderedProminent)
            default:
                if notice.canRetry { Button(L.QA.retry) { perform(.retry) } }
            }
        }
        .controlSize(.small)
    }

    private var ai: String { AskTexts.ai(state) }
    private var provider: AIProviderKind { state.settings.assist.mode.providerKind ?? state.settings.agentProvider }

    private var icon: String {
        switch notice {
        case .confirm: return "lock.shield"
        case .blocked: return "hand.raised"
        case .limited, .softCap, .hardCap, .burst, .budget: return "gauge.with.dots.needle.100percent"
        case .notLoggedIn: return "person.crop.circle.badge.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice {
        case .blocked, .hardCap: return .red
        case .confirm, .limited, .softCap, .notLoggedIn, .privacyUnchecked: return .orange
        default: return .secondary
        }
    }

    private var title: String {
        switch notice {
        case .off: return L.QA.offTitle
        case .notLoggedIn(let reason): return reason.text(L.lang, loginProblem: true, provider: provider)
        case .limited(let until): return L.QA.limited(ai, until.map { Self.time($0) })
        case .softCap(let n): return L.QA.softCap(n)
        case .hardCap(let n): return L.QA.hardCap(n)
        case .burst: return L.QA.burst
        case .budget: return L.QA.budget
        case .blocked: return L.Policy.blocked
        case .privacyUnchecked: return L.QA.privacyUnchecked
        case .notInstalled: return L.QA.notInstalled(provider.cliName)
        case .unsupported: return L.QA.unsupported
        case .expired: return L.QA.expired
        case .timeout: return L.QA.timeout
        case .overloaded: return L.QA.overloaded
        case .failed: return L.QA.failed
        case .confirm: return L.QA.confirmTitle(ai)
        }
    }

    private var detail: String? {
        switch notice {
        case .notLoggedIn: return L.QA.loginHint(provider)
        case .blocked: return L.QA.blockedHint
        case .privacyUnchecked: return L.QA.privacyUncheckedHint
        case .confirm(let reasons, _, _): return AssistPolicyText.confirmation(reasons)
        default: return nil
        }
    }

    /// `15:45`, or `10/2 15:45` when not today (the provider pill's form).
    static func time(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
        let clock = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return cal.isDate(d, inSameDayAs: now) ? clock : "\(c.month ?? 0)/\(c.day ?? 0) \(clock)"
    }
}

/// Ask with `assist.mode` off: what Ask sends and to whom, and one button per subscription. Turning
/// it on sends nothing; the next question still needs its own click.
struct AskEnableCard: View {
    let state: AppState
    var onEnabled: () -> Void = {}

    /// The first-use explanation version this card records (`assist.consentVersion`).
    static let consentVersion = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.QA.offTitle, systemImage: "bubble.left.and.text.bubble.right")
                .font(.callout.weight(.semibold))
            Text(L.QA.offBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(providers, id: \.self) { kind in
                    if kind == providers.first {
                        Button(L.QA.useProvider(kind.shortName)) { enable(kind) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(L.QA.useProvider(kind.shortName)) { enable(kind) }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
            Text(L.QA.offFooter).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18)))
    }

    /// The card provider first.
    private var providers: [AIProviderKind] {
        let first = state.settings.agentProvider
        return [first] + AIProviderKind.allCases.filter { $0 != first }
    }

    private func enable(_ kind: AIProviderKind) {
        var a = state.settings.assist
        a.mode = kind.assistMode
        a.consentVersion = max(a.consentVersion, Self.consentVersion)
        state.settings.assist = a
        onEnabled()
    }
}
