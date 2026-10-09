import Foundation
import Testing
@testable import PaperDeckCore

/// Review fixes safety-9 (dismiss during the hand-off), integrity-5 (dismiss keeps the triage
/// bookkeeping in sync; a reopened card offers 「让 AI 分析」 again) and runtime-2 (limited,
/// needs-login and failed triage is withdrawn too, and never retried for a dismissed card).
@Suite(.serialized) struct RFADismissTests {
    typealias K = MailSyncKit
    typealias R = RFAKit

    /// 「忽略」 while 「让 AI 分析」 is still building the job (first page of the attachment):
    /// nothing is sent, nothing is counted.
    @Test func dismissDuringTheHandOffIsNeverSent() async throws {
        let mock = MockAgentProvider()
        let pdf = R.GatedPDF()
        try await R.run(mode: .mock, mock: mock, pdf: pdf) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(try await env.db.mailItems(messagePK: m.pk).contains { $0.origin == .attachment && $0.pdfPath != nil })

            pdf.arm()
            let engine = env.engine
            let request = Task { try? await engine.requestMailAI(messageID: m.id) }
            #expect(await K.eventually { pdf.enteredWhileArmed > 0 })
            try await env.engine.dismissMail(messageID: m.id)
            pdf.release()
            _ = await request.value
            try await Task.sleep(for: .milliseconds(300))

            #expect(await mock.calls == 0)
            let after = try await env.message(m.internetMessageID)
            #expect(after.state == .dismissed)
            #expect(after.triageState != .queued && after.triageState != .done)
            #expect(!after.triageConsented)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            #expect(await env.engine.agents.queuedTriageMessagePKs().isEmpty)
            #expect(await env.engine.mailTriage.usage().used == 0)
        }
    }

    @Test func dismissWithdrawsTheLaneJobAndReopenOffersAIAgain() async throws {
        let mock = MockAgentProvider(delay: .milliseconds(400))
        try await R.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try R.alert(1))
            await env.source().add("a2.eml", try R.alert(2))
            await env.sync()
            #expect(await K.eventually { await mock.calls == 1 })
            let second = try await env.message(R.alertID(2))
            #expect(await env.engine.agents.queuedTriageMessagePKs() == [second.pk])

            try await env.engine.dismissMail(messageID: second.id)
            #expect(await env.engine.agents.queuedTriageMessagePKs().isEmpty)
            #expect(!(await env.engine.mailTriage.laneMessagePKs().contains(second.pk)))
            #expect(await R.triageState(env, second.internetMessageID) == MailTriageState.none)
            #expect(await K.eventually { await R.triageState(env, R.alertID(1)) == .done })
            #expect(await env.engine.mailTriage.usage().used == 1)          // the withdrawn one was refunded
            try await Task.sleep(for: .milliseconds(200))
            #expect(await mock.calls == 1)

            try await env.engine.reopenMail(messageID: second.id)
            let card = try #require(try await env.engine.mailCard(id: second.id))
            #expect(card.message.state == .pending && card.canRequestAI)
            #expect(try await env.engine.requestMailAI(messageID: second.id) == .queued)
            #expect(await K.eventually { await R.triageState(env, second.internetMessageID) == .done })
            #expect(await mock.calls == 2)
        }
    }

    @Test func dismissWhileLimitedWithdrawsTheJob() async throws {
        let mock = MockAgentProvider(script: [.usageLimit(resetsAt: K.start.addingTimeInterval(3600))])
        try await R.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try R.alert(1))
            await env.sync()
            #expect(await K.eventually { await R.triageState(env, R.alertID(1)) == .limited })
            let m = try await env.message(R.alertID(1))
            #expect(await env.engine.agents.queuedTriageMessagePKs() == [m.pk])

            try await env.engine.dismissMail(messageID: m.id)
            #expect(await env.engine.agents.queuedTriageMessagePKs().isEmpty)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            let after = try await env.message(m.internetMessageID)
            #expect(after.state == .dismissed && after.triageState == MailTriageState.none && after.triageError == nil)
        }
    }

    @Test func aDismissedFailedTriageIsNotRetried() async throws {
        let mock = MockAgentProvider(script: [.invalidOutput])
        try await R.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try R.alert(1))
            await env.sync()
            #expect(await K.eventually { await R.triageState(env, R.alertID(1)) == .failed })
            let m = try await env.message(R.alertID(1))
            try await env.engine.dismissMail(messageID: m.id)
            env.advance(301)
            await env.engine.mail.settingsDidChange()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 1)
            #expect(await R.triageState(env, m.internetMessageID) == MailTriageState.none)

            // Even a row left `failed` on a dismissed card (an older build) is not retried.
            try await env.db.modifyMailMessage(pk: m.pk) { $0.triageState = .failed; $0.triageNotBefore = K.start }
            await env.engine.mail.settingsDidChange()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 1)
        }
    }
}
