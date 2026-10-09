import AppKit
import SwiftUI
import PaperDeckCore

/// An answer's inline Markdown with its citation markers as in-process links
/// (`paperdeck-cite://<k>`, k = the marker's index). Every other link is dropped: the final answer's
/// links were already made inert by the lane's sanitizer, and a streamed fragment must not become
/// clickable either.
enum AskMarkdown {
    static func attributed(_ text: String, multi: Bool) -> AttributedString {
        let source = QACitations.linkedMarkdown(text, multi: multi)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var out = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
        for run in out.runs {
            guard let url = run.link else { continue }
            if url.scheme == QACitations.linkScheme {
                out[run.range].foregroundColor = .accentColor
                out[run.range].underlineStyle = .none
            } else {
                out[run.range].link = nil
            }
        }
        return out
    }

    /// The marker index of a citation link.
    static func index(of url: URL) -> Int? {
        guard url.scheme == QACitations.linkScheme else { return nil }
        return Int(url.host() ?? "")
    }

    /// The answer as plain text for Copy (citations as "(p. 3)").
    static func plain(_ text: String, multi: Bool) -> String {
        QACitations.plain(text, multi: multi)
    }
}

/// The blocks of one answer (paragraphs, lists, quotes) with clickable citations.
struct AnswerBlocksView: View {
    let blocks: [QAAnswerFormat.Block]
    let multi: Bool
    /// The citations of the marker `k` were clicked.
    let onCite: (Int) -> Void

    var body: some View {
        // Marker indices run through the whole answer, so each block knows where its markers start.
        let offsets = blockOffsets
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                row(block, offset: offsets[i])
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let k = AskMarkdown.index(of: url) { onCite(k) }
            return .handled
        })
    }

    private var blockOffsets: [Int] {
        var out: [Int] = []
        var n = 0
        for b in blocks {
            out.append(n)
            n += QACitations.tokens(in: Self.text(b)).count
        }
        return out
    }

    static func text(_ b: QAAnswerFormat.Block) -> String {
        switch b {
        case .paragraph(let s), .bullet(let s), .quote(let s), .numbered(_, let s): return s
        }
    }

    @ViewBuilder
    private func row(_ block: QAAnswerFormat.Block, offset: Int) -> some View {
        switch block {
        case .paragraph(let s):
            line(s, offset: offset)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                line(s, offset: offset)
            }
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(n).").monospacedDigit().foregroundStyle(.secondary)
                line(s, offset: offset)
            }
        case .quote(let s):
            line(s, offset: offset)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
        }
    }

    /// One block's text; its marker links are renumbered to the answer-wide indices.
    private func line(_ s: String, offset: Int) -> some View {
        var k = offset - 1
        let renumbered = QACitations.replacingTokens(in: s) { t in
            k += 1
            return "[\(t.citations.map { QACitations.display($0, multi: multi) }.joined(separator: "; "))](\(QACitations.linkScheme)://\(k))"
        }
        return Text(Self.inline(renumbered))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Already-linked Markdown → attributed text (only our citation links survive).
    static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var out = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in out.runs {
            guard let url = run.link else { continue }
            if url.scheme == QACitations.linkScheme {
                out[run.range].foregroundColor = .accentColor
            } else {
                out[run.range].link = nil
            }
        }
        return out
    }
}

/// One citation chip: `p. 7`, `pp. 7–9`, `P2 · p. 5`, `P2`, with the printed label when it differs.
/// Dimmed when it is invalid — the page or paper doesn't exist, it names no paper among several, or
/// its page wasn't sent with the question (the help says which); outlined (dashed) when no sentence
/// of the page supports the claim.
struct CitationChip: View {
    let citation: QACitation
    let multi: Bool
    /// Papers in the thread (P1…Pn).
    var paperCount: Int = 1
    let action: () -> Void

    var body: some View {
        let unverified = citation.valid && citation.quoteFound == false
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(citation.valid && !unverified ? 0.13 : 0.0)))
                .overlay {
                    if unverified {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else if !citation.valid {
                        Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    }
                }
                .foregroundStyle(citation.valid ? Color.accentColor : Color.secondary)
                .opacity(citation.valid ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }

    private var title: String {
        let base = QACitations.display(citation, multi: multi)
        guard let label = citation.label else { return base }
        return base + " (\(label))"
    }

    private var help: String {
        if let problem = QACitations.problem(of: citation, paperCount: paperCount) {
            switch problem {
            case .unknownPaper: return L.QA.unknownPaper
            case .pageMissing: return L.QA.pageMissing(citation.page ?? 0)
            case .ambiguous: return L.QA.ambiguousPaper(citation.page ?? 0)
            case .notSent: return L.QA.notSent(citation.page ?? 0)
            }
        }
        guard let page = citation.page else { return L.QA.fromCard }
        var lines = [L.QA.openPage(page)]
        if let label = citation.label { lines.append(L.QA.printedPage(label)) }
        if citation.quoteFound == false { lines.append(L.QA.unverified(page)) }
        if let quote = citation.quote { lines.append("“" + quote + "”") }
        return lines.joined(separator: "\n")
    }
}

/// The unique citations of an answer, in order of first appearance.
struct CitationChipRow: View {
    let citations: [QACitation]
    let multi: Bool
    var paperCount: Int = 1
    let open: (QACitation) -> Void

    var body: some View {
        let unique = Self.unique(citations)
        if !unique.isEmpty {
            FlowRow(spacing: 5) {
                ForEach(Array(unique.enumerated()), id: \.offset) { _, c in
                    CitationChip(citation: c, multi: multi, paperCount: paperCount) { open(c) }
                }
            }
        }
    }

    static func unique(_ cites: [QACitation]) -> [QACitation] {
        var seen = Set<String>()
        return cites.filter { seen.insert("\($0.paper)|\($0.page ?? 0)|\($0.endPage ?? 0)").inserted }
    }
}

/// Where citation clicks go (READING_ASSIST_PLAN §4 `ReaderRouting`): the built-in reader at the cited
/// physical page with the supporting sentence highlighted (`AppState.reader`, C4); PagePeek when the
/// reader isn't part of the build.
enum AskCitationRouting {
    static func router(_ state: AppState) -> any ReaderRouting {
        ReaderRouter.isAvailable ? state.reader : PagePeekRouter(state: state)
    }

    /// Opens `c` (P1… index into `paperIDs`). A page the PDF doesn't have opens the first page; a
    /// page that wasn't sent opens at that page (it exists); a citation naming no paper among several
    /// opens nothing; a card-only citation (`[P2]`) opens the paper with the user's opener.
    static func open(_ c: QACitation, paperIDs: [String], state: AppState) {
        guard paperIDs.indices.contains(c.paper - 1) else { return }
        let page: Int? = c.page == nil ? nil : (c.valid || c.problem == .notSent ? c.page : 1)
        router(state).open(paperID: paperIDs[c.paper - 1], page: page, highlight: c.quoteFound == true ? c.quote : nil)
    }
}
