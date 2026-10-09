import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// One Help topic (tutorial, troubleshooting entry or reference page): the live "Status now"
/// header, its steps with their live states, commands and actions, then related topics.
/// Also embedded by the onboarding Mail page (`compact`).
struct TutorialView: View {
    let topic: GuideTopic
    let facts: SetupFactsCollector
    let runner: GuideActionRunner
    var compact = false

    var body: some View {
        let f = facts.facts
        let manual = facts.guide.manualDone
        let lang = L.lang
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if !compact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(topic.title(lang)).font(.title2.weight(.semibold))
                    if GuideEvaluator.appliesNow(topic, f) { AppliesNowBadge() }
                }
                if !topic.summary(lang).isEmpty {
                    GuideText(topic.summary(lang)).foregroundStyle(.secondary)
                }
            }
            TopicStatusLine(status: GuideEvaluator.status(of: topic, f, manualDone: manual),
                            troubleshoot: topic.kind == .troubleshoot)
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                    StepRow(index: i, step: step, topic: topic,
                            state: GuideEvaluator.evaluate(step: i, in: topic, f, manualDone: manual),
                            facts: facts, runner: runner)
                }
            }
            if !compact {
                footer(lang)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A topic that checks the AI CLIs probes them once when it appears (zero quota).
        .task(id: topic.id) { if Self.checksProviders(topic) { facts.kick(providers: true) } }
    }

    static func checksProviders(_ t: GuideTopic) -> Bool {
        t.steps.contains { step in
            guard case .check(let c) = step.verification else { return false }
            switch c {
            case .providerInstalled, .providerSignedIn, .providerSubscription: return true
            default: return false
            }
        }
    }

    @ViewBuilder private func footer(_ lang: UILang) -> some View {
        if !topic.related.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L.Help.related).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                FlowRow {
                    ForEach(topic.related, id: \.self) { id in
                        Button(GuideCatalog.topic(id)?.title(lang) ?? id.rawValue) { runner.openTopic(id) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        Divider()
        HStack(spacing: 12) {
            Text(L.Help.stillStuck).foregroundStyle(.secondary)
            Button(L.Help.troubleshooting) { runner.openTopic(HelpCenterModel.troubleshootingID) }.buttonStyle(.link)
            Button(L.Help.copyDiagnostics) { runner.openTopic(.diagnostics) }.buttonStyle(.link)
            Spacer()
            Text(L.Help.lastReviewed(topic.lastReviewed)).font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
    }
}

/// One step: state, text, the reason of a problem, commands, actions and (manual steps) a tick.
private struct StepRow: View {
    let index: Int
    let step: GuideStep
    let topic: GuideTopic
    let state: CheckState
    let facts: SetupFactsCollector
    let runner: GuideActionRunner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if state == .notApplicable {
                    Text("\(index + 1)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    CheckStateIcon(state: state)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                GuideText(step.text(L.lang))
                if case .problem(let why) = state {
                    Text(why(L.lang)).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(step.commands, id: \.self) { CommandBox(command: $0) }
                GuideActionButtons(actions: step.actions, runner: runner)
                if case .manual = step.verification {
                    let key = GuideEvaluator.manualKey(topic: topic.id, step: step.id)
                    let done = facts.guide.manualDone.contains(key)
                    Button(done ? L.Help.unmarkDone : L.Help.markDone) { facts.guide.toggleManual(key) }
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1). \(CheckStateIcon.label(state))")
    }
}

struct AppliesNowBadge: View {
    var body: some View {
        Text(L.Help.appliesNow)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// Wraps its children onto several lines (related-topic links).
struct FlowRow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + 6; line = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + 6; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
