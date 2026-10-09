import SwiftUI
import PaperDeckCore

/// 「发送给 AI 的内容」 (MAIL_DESIGN Part A §3 / §4 transparency): whether this email went to the AI
/// — provider, model, bytes — or 「未发送给 AI（本地规则）」, and on request the exact stdin the
/// triage lane gets (`MailTriageCoordinator.previewJob`: built like a real job, never enqueued,
/// never counted). Shown verbatim, monospaced, selectable; never logged.
struct MailSentPreview: View {
    let state: AppState
    let card: MailCard
    let aiMode: MailSettings.AIMode
    /// Opens with the content shown (renders, deep inspection).
    var startExpanded = false

    @State private var expanded = false
    @State private var load: Load = .idle

    private enum Load: Equatable {
        case idle, loading
        case loaded(text: String, meta: String)
        case unavailable(String)
    }

    private var m: MailMessage { card.message }

    /// What the preview depends on (the message as stored; never its text, which only the
    /// full card carries and which the preview never reads itself — `previewJob` does).
    private struct Revision: Equatable {
        let updatedAt: Date, bodyPurged: Bool, triageState: MailTriageState, triageSource: MailTriageSource?
        let triageAttempt: Int, triageProvider: String?, triageConsented: Bool
        init(_ m: MailMessage) {
            updatedAt = m.updatedAt; bodyPurged = m.bodyPurged; triageState = m.triageState; triageSource = m.triageSource
            triageAttempt = m.triageAttempt; triageProvider = m.triageProvider; triageConsented = m.triageConsented
        }
    }
    /// An AI result was applied, or an attempt reached the provider and failed (timeout, invalid
    /// output… — `triageAttempt` only counts runs that were actually sent).
    private var sent: Bool { m.triageSource == .ai || m.triageAttempt > 0 }
    private var canPreview: Bool { aiMode == .ai && card.rule?.aiPolicy != .never && !m.bodyPurged }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(statusText) } icon: { Image(systemName: sent ? "paperplane.fill" : "lock.fill") }
                .font(.system(size: 12))
                .foregroundStyle(sent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if canPreview {
                Button {
                    expanded.toggle()
                    if expanded, load == .idle { Task { await build() } }
                } label: {
                    Label(expanded ? L.Mail.hideContent : L.Mail.showContent,
                          systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                if expanded { content }
            }
        }
        .onChange(of: card.id) { _, _ in
            expanded = false
            load = .idle
        }
        // The email changed (its full card was loaded again after a `.mail(pk:)` change — a triage
        // result, the text purged…): an open preview is built again, a closed one starts over.
        .onChange(of: Revision(card.message)) { _, _ in
            guard load != .idle else { return }
            if expanded, canPreview {
                Task { await build() }
            } else {
                load = .idle
                expanded = false
            }
        }
        .task {
            if startExpanded, canPreview, !expanded {
                expanded = true
                await build()
            }
        }
    }

    private var statusText: String {
        if sent {
            let provider = m.triageProvider.flatMap(AIProviderKind.init(rawValue:))?.shortName ?? m.triageProvider ?? L.ai
            return L.Mail.sentSummary(provider: provider, model: DetailFormat.modelName(m.triageModel) ?? m.triageModel,
                                      size: m.triageStdinBytes.map(L.Mail.bytes), when: nil)
        }
        if aiMode != .ai { return L.Mail.notSentLocal }
        if card.rule?.aiPolicy == .never { return L.Mail.notSentSender }
        if m.bodyPurged { return L.Mail.notSentPurged }
        return L.Mail.notSentYet
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L.Mail.previewLoading).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .unavailable(let why):
            Text(verbatim: why).font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .loaded(let text, let meta):
            VStack(alignment: .leading, spacing: 6) {
                Text(sent ? L.Mail.previewRebuilt : L.Mail.previewWouldSend)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(verbatim: meta).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Spacer()
                    Button(L.Mail.copy) { state.copyText(text) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: Self.boxHeight(text))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                Text(L.Mail.previewFixed)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A nested scroll view has no height of its own inside the inspector's scroll view: size it
    /// to the text (≈ 13 pt per wrapped line of ~58 characters), 60…320 pt.
    private static func boxHeight(_ text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 57) / 58) }
        return min(320, max(60, CGFloat(lines) * 13 + 16))
    }

    private func build() async {
        load = .loading
        let id = card.id
        do {
            guard let job = try await state.engine.mailTriage.previewJob(messageID: id) else {
                load = .unavailable(L.Mail.previewUnavailable)
                return
            }
            guard card.id == id else { return }
            let text = String(decoding: job.request.stdin, as: UTF8.self)
            let provider = job.provider?.shortName ?? L.ai
            load = .loaded(text: MailInboxRules.text(text, limit: 60_000),
                           meta: L.Mail.previewMeta(provider: provider, model: job.request.model,
                                                    size: L.Mail.bytes(job.request.stdin.count)))
        } catch let e as MailTriageError {
            load = .unavailable(e.message(L.lang))
        } catch {
            load = .unavailable(L.Mail.previewUnavailable)
        }
    }
}
