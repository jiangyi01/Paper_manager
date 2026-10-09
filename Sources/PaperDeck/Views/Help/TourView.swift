import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The 1-minute feature tour: the `tour` topic's steps as pages, each with a drawn illustration,
/// a [Show Me] that drives the real UI (the step's first action) and a live "Try it" line (the
/// step's check). Finishing records `guide.activity.tourCompleted`.
struct TourView: View {
    let facts: SetupFactsCollector
    let runner: GuideActionRunner
    var topic: GuideTopic? = GuideCatalog.topic(.tour)
    var onDone: () -> Void = {}
    @State private var page = 0

    var body: some View {
        if let topic, !topic.steps.isEmpty {
            let i = min(page, topic.steps.count - 1)
            let step = topic.steps[i]
            let (title, text) = Self.split(step.text(L.lang))
            VStack(spacing: 18) {
                TourIllustration(stepID: step.id, index: i)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title2.weight(.semibold))
                    if !text.isEmpty { GuideText(text).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                tryIt(step, index: i, topic: topic)
                Spacer(minLength: 0)
                HStack {
                    Text(L.Help.tourPage(i + 1, topic.steps.count)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if i > 0 { Button(L.Help.tourBack) { page = i - 1 }.keyboardShortcut("[", modifiers: .command) }
                    if i + 1 < topic.steps.count {
                        Button(L.Help.tourNext) { page = i + 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        Button(L.Help.tourDone) {
                            facts.guide.record(.tourCompleted)
                            onDone()
                        }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L.Help.tourUnavailable).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func tryIt(_ step: GuideStep, index: Int, topic: GuideTopic) -> some View {
        let state = GuideEvaluator.evaluate(step: index, in: topic, facts.facts, manualDone: facts.guide.manualDone)
        HStack(spacing: 10) {
            if let show = step.actions.first {
                Button {
                    runner.perform(show)
                } label: {
                    Label(L.Help.showMe, systemImage: "hand.point.up.left")
                }
                .disabled(!runner.isAvailable(show))
            }
            if state != .notApplicable {
                CheckStateIcon(state: state)
                Text(state == .done ? L.Help.triedIt : L.Help.tryIt + " " + (step.actions.first.map(runner.title) ?? ""))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    /// "Title\nBody" (or "**Title** — body") → (title, body).
    static func split(_ s: String) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(of: "\n") {
            return (clean(String(t[..<nl])), String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for sep in [" — ", " – ", "：", ": "] {
            if let r = t.range(of: sep) {
                return (clean(String(t[..<r.lowerBound])), String(t[r.upperBound...]))
            }
        }
        return (clean(t), "")
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// Drawn from SF Symbols and shapes (no image assets).
struct TourIllustration: View {
    let stepID: String
    let index: Int

    var body: some View {
        ZStack {
            switch kind {
            case .drop:
                HStack(spacing: 26) {
                    Image(systemName: "doc.richtext.fill").font(.system(size: 54)).foregroundStyle(.tint)
                    Image(systemName: "arrow.right").font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.35)).frame(width: 14, height: 110)
                    Image(systemName: "menubar.rectangle").font(.system(size: 54)).foregroundStyle(.secondary)
                }
            case .today:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: i == 0 ? "exclamationmark.circle.fill" : "circle")
                                .foregroundStyle(i == 0 ? .orange : .secondary)
                            RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.25)).frame(width: 180 - CGFloat(i * 30), height: 12)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "calendar").font(.system(size: 30)).foregroundStyle(.tint).offset(x: 50, y: -18)
                }
            case .card:
                HStack(spacing: 18) {
                    Image(systemName: "rectangle.and.text.magnifyingglass").font(.system(size: 54)).foregroundStyle(.tint)
                    Image(systemName: "checklist").font(.system(size: 54)).foregroundStyle(.green)
                }
            case .ai:
                HStack(spacing: 18) {
                    Image(systemName: "sparkles").font(.system(size: 54)).foregroundStyle(.purple)
                    Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.secondary)
                }
            case .mail:
                HStack(spacing: 18) {
                    Image(systemName: "envelope.fill").font(.system(size: 50)).foregroundStyle(.tint)
                    Image(systemName: "arrow.right").font(.system(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 50)).foregroundStyle(.secondary)
                }
            case .reminders:
                HStack(spacing: 18) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 50)).foregroundStyle(.orange)
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 50)).foregroundStyle(.tint)
                }
            case .data:
                HStack(spacing: 18) {
                    Image(systemName: "folder.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    VStack(spacing: 6) {
                        Image(systemName: "doc.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("card.json").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)
    }

    private enum Kind { case drop, today, card, ai, mail, reminders, data }

    private var kind: Kind {
        let id = stepID.lowercased()
        if id.contains("drop") { return .drop }
        if id.contains("today") { return .today }
        if id.contains("card") { return .card }
        if id.contains("mail") { return .mail }
        if id.contains("remind") || id.contains("widget") { return .reminders }
        if id.contains("data") || id.contains("library") { return .data }
        if id == "ai" || id.hasSuffix("-ai") || id.contains("-ai-") { return .ai }
        return [Kind.drop, .today, .card, .ai, .mail, .reminders, .data][index % 7]
    }
}
