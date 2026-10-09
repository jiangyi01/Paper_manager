import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes, the App side (read from the sources the tests were compiled from — the App target
/// can't be imported): QA-4 U4 — a question is sent only from a Button's action, never from
/// `.task` / `.onAppear` / `.onChange`; the Ask views decide what a click sends through Core's
/// tested `QASendPlan` / `QAIntent` (QA-6, QA-12, U2, U3); QA-2 — Q&A is bound at launch, so
/// `qa.json` follows privacy changes all session; QA-13 — the chip's help comes from the
/// citation's `problem`; QA-14 — one range for papers per question; QA-10 — the composer's note.
@Suite(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct QAFixSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    static let askViews = LintRepo.swiftFiles(under: "Sources/PaperDeck/Views/Ask") + ["Sources/PaperDeck/Views/Detail/AskTab.swift"]

    /// U4: every call that sends sits on a Button's line (its action closure). A send from a
    /// lifecycle modifier would fire with no click.
    @Test func questionsAreSentOnlyFromButtonActions() throws {
        var checked = 0
        for path in Self.askViews {
            let lines = try Self.text(path).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard code.contains("perform(") else { continue }
                // Declarations and the hosting views' closures that receive the click's intent.
                if code.contains("func perform(") || code.contains("let perform:") || code.contains("perform: perform")
                    || code.contains("session.perform(intent, ticket:") { continue }
                checked += 1
                #expect(code.contains("Button"), "\(path):\(i + 1): a send outside a Button action: \(line)")
            }
            // No lifecycle modifier block contains a send.
            let source = lines.joined(separator: "\n")
            for modifier in [".task", ".onAppear", ".onChange", ".onReceive", ".onDisappear", "DispatchQueue.main.async", "Timer."] {
                var rest = Substring(source)
                while let r = rest.range(of: modifier) {
                    let block = rest[r.upperBound...].prefix(400)
                    let body = block.prefix { $0 != "}" }
                    #expect(!body.contains("perform("), "\(path): \(modifier) sends: \(body)")
                    rest = rest[r.upperBound...]
                }
            }
        }
        #expect(checked >= 6, "the lint saw the sends: \(checked)")
    }

    @Test func theAskViewsDecideWhatToSendThroughCore() throws {
        let session = try Self.text("Sources/PaperDeck/Views/Ask/AskSession.swift")
        #expect(session.contains("typealias AskIntent = QAIntent"))
        #expect(session.contains("QASendPlan.send(intent, current: options, last: lastAsk, threadID: thread?.id,"))
        #expect(session.contains("intent.gesture(firstQuestion: messages.isEmpty)"))
        #expect(session.contains("lastAsk = QASentQuestion(threadID: thread?.id, question: question, options: options)"))
        // The last question is forgotten whenever the thread or the papers change.
        for function in ["func newThread()", "func select(threadID: String)", "func setPapers(_ ids: [String])"] {
            let start = try #require(session.range(of: function))
            let body = session[start.upperBound...].prefix(700)
            #expect(body.contains("lastAsk = nil"), "\(function)")
        }
        #expect(!session.contains("privacyAcknowledged = true"), "only Core's plan sets the acknowledgement")
        // "Answer in …" names the clicked answer.
        let thread = try Self.text("Sources/PaperDeck/Views/Ask/AskThreadView.swift")
        #expect(thread.contains("perform(.translate(otherLanguage, messageID: message.id))"))
        #expect(!thread.contains("perform(.translate(otherLanguage))"))
    }

    @Test func qaIsBoundAtLaunch() throws {
        let router = try Self.text("Sources/PaperDeck/Views/Ask/AskRouter.swift")
        #expect(router.contains("await engine.recoverQA()"))
        let delegate = try Self.text("Sources/PaperDeck/App/AppDelegate.swift")
        #expect(delegate.contains("AskRouter.install(state)"))
        // The policy toggle still rewrites qa.json at once.
        let policy = try Self.text("Sources/PaperDeckCore/Engine/OperationsPolicy.swift")
        #expect(policy.contains("await syncQASidecar(paperID: paperID)"))
    }

    @Test func theChipsHelpComesFromTheCitationsProblem() throws {
        let views = try Self.text("Sources/PaperDeck/Views/Ask/AskAnswerViews.swift")
        #expect(views.contains("QACitations.problem(of: citation, paperCount: paperCount)"))
        for c in ["case .unknownPaper: return L.QA.unknownPaper", "case .pageMissing: return L.QA.pageMissing(",
                  "case .ambiguous: return L.QA.ambiguousPaper(", "case .notSent: return L.QA.notSent("] {
            #expect(views.contains(c), "\(c)")
        }
        #expect(views.contains("CitationChip(citation: c, multi: multi, paperCount: paperCount)"))
        let thread = try Self.text("Sources/PaperDeck/Views/Ask/AskThreadView.swift")
        #expect(thread.contains("paperCount: session.paperIDs.count"))
        #expect(thread.contains("QACitations.resolve(first, stored: message.citations, pageCounts: counts)"))
    }

    @Test func onePapersPerQuestionRangeEverywhereTheAppOwns() throws {
        #expect(AssistSettings.qaMultiMaxRange == 2...20)
        let section = try Self.text("Sources/PaperDeck/Views/Settings/QASettingsSection.swift")
        #expect(section.contains("in: AssistSettings.qaMultiMaxRange"))
        #expect(!section.contains("in: 2...20") && !section.contains("2...50"))
        let window = try Self.text("Sources/PaperDeck/Windows/AskWindowController.swift")
        #expect(window.contains("AssistSettings.qaMultiMaxRange"))
        #expect(window.contains("min(max(state.settings.assist.qaMultiMax, range.lowerBound), range.upperBound)"))
    }

    @Test func theComposerSaysWhenAQuestionIsCut() throws {
        let thread = try Self.text("Sources/PaperDeck/Views/Ask/AskThreadView.swift")
        #expect(thread.contains("QAContextBuilder.questionIsCut(session.draft)"))
        #expect(thread.contains("L.QA.questionTooLong(QAContextBuilder.questionLimit)"))
        let strings = try Self.text("Sources/PaperDeck/App/L10n+qa.swift")
        for name in ["questionTooLong(1_000)", "cutOff", "ambiguousPaper(5)", "notSent(11)", "privacyUnchecked", "privacyUncheckedHint"] {
            #expect(strings.contains(name), "`L.QA.all` lists \(name) (the en ≠ zh self-test)")
        }
        let session = try Self.text("Sources/PaperDeck/Views/Ask/AskSession.swift")
        #expect(session.contains("case .invalidOutput(QAService.outputCapKind): return nil"))
        #expect(session.contains("case .generic(QAService.privacyUncheckedCode): return .privacyUnchecked"))
    }
}
