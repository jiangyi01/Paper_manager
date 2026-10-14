import SwiftUI
import PaperDeckCore

// Chips of the Mail panel. Colour always comes with text (and often a glyph); inks and fills
// come from ChipPalette (≥ 4.5:1 on their own fill in both appearances).

/// A small capsule: optional SF Symbol + text in one palette hue (nil hue → neutral grey).
struct MailChip: View {
    let text: String
    var symbol: String?
    var hue: Int?
    var dashed = false
    var help: String?

    var body: some View {
        let ink = hue.map { ChipPalette.color(hue: $0) } ?? Color.secondary
        let fill = hue.map { ChipPalette.fill(hue: $0) } ?? Color.primary.opacity(0.06)
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(verbatim: text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(fill))
        .overlay {
            if dashed {
                Capsule().strokeBorder(ink.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .fixedSize()
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The state chip of a paper row: 附件 PDF · 可下载 · 需要 PDF · 下载中 · 已在库中 · 已合并 · 已跳过 ·
/// 附件文档 · 需导出 · 共享链接 — or 转换中 while 「转换为 PDF 并合并」 runs (`converting`).
/// Rows the user must bring a PDF to are dashed orange (需要 PDF · 需导出 · 共享链接).
struct MailItemChipView: View {
    let chip: MailInboxRules.ItemChip
    var converting = false

    var body: some View {
        if converting {
            MailChip(text: L.Mail.chipConverting, symbol: Self.convertingSymbol, hue: Self.convertingHue)
        } else {
            MailChip(text: L.Mail.chip(chip), symbol: Self.symbol(chip), hue: Self.hue(chip), dashed: Self.dashed(chip))
        }
    }

    /// The user brings the PDF (dashed, like 需要 PDF).
    static func dashed(_ c: MailInboxRules.ItemChip) -> Bool {
        c == .needsPDF || c == .openOnly || c == .shareLink
    }

    static let convertingSymbol = "arrow.triangle.2.circlepath"
    static let convertingHue = 6                // indigo, like 下载中

    static func symbol(_ c: MailInboxRules.ItemChip) -> String {
        switch c {
        case .attachment: return "paperclip"
        case .downloaded: return "arrow.down.doc"
        case .downloadable: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.dotted"
        case .needsPDF: return "doc.badge.plus"
        case .inLibrary: return "books.vertical"
        case .merged: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .convertible: return "doc.richtext"
        case .openOnly: return "square.and.arrow.up"
        case .shareLink: return "link"
        }
    }

    static func hue(_ c: MailInboxRules.ItemChip) -> Int? {
        switch c {
        case .attachment: return 0          // blue
        case .downloaded: return 4          // teal
        case .downloadable: return 1        // green
        case .downloading: return 6         // indigo
        case .needsPDF: return 3            // orange
        case .inLibrary: return 2           // purple
        case .merged: return 1              // green
        case .skipped: return nil
        case .convertible: return 0         // blue, like 附件 PDF (attached; PaperDeck makes the PDF)
        case .openOnly: return 3            // orange, like 需要 PDF (the user exports it)
        case .shareLink: return 3           // orange, like 需要 PDF (the user downloads it)
        }
    }
}

/// 导师请求 / Request · 组会 / Journal club · 论文提醒 / Alert · 分享 / FYI.
struct MailRequestBadgeView: View {
    let badge: MailInboxRules.RequestBadge
    let advisor: Bool

    var body: some View {
        MailChip(text: L.Mail.badge(badge, advisor: advisor), symbol: symbol, hue: hue)
    }

    private var symbol: String {
        switch badge {
        case .request: return "person.fill.questionmark"
        case .journalClub: return "person.3.fill"
        case .alert: return "bell.fill"
        case .fyi: return "arrowshape.turn.up.right.fill"
        case .other: return "envelope"
        }
    }

    private var hue: Int? {
        switch badge {
        case .request: return 9             // red
        case .journalClub: return 5         // pink
        case .alert: return 0               // blue
        case .fyi: return 4                 // teal
        case .other: return nil
        }
    }
}

/// 「邮件 DDL ≈10/3」 — a hint, not a commitment (dotted unless confident; red when passed).
struct MailDueChip: View {
    let hint: MailInboxRules.DueHint

    var body: some View {
        MailChip(text: L.Mail.dueChip(SharedStrings.monthDay(hint.date), confident: hint.confident, past: hint.isPast),
                 symbol: "calendar", hue: hint.isPast ? 9 : 3, dashed: !hint.confident,
                 help: L.Mail.dueHelp(hint.evidence))
    }
}

/// The triage's priority hint (high only ever for people).
struct MailPriorityChip: View {
    let priority: Priority

    var body: some View {
        switch priority {
        case .high: MailChip(text: L.Mail.priorityHigh, symbol: "flag.fill", hue: 9)
        case .low: MailChip(text: L.Mail.priorityLow, symbol: "arrow.down", hue: nil)
        case .normal: EmptyView()
        }
    }
}

/// The account the email came from (「手动导入」 for dropped .eml files).
struct MailAccountChip: View {
    let card: MailCard

    var body: some View {
        MailChip(text: Self.name(card), symbol: Self.symbol(card), hue: nil)
    }

    static func name(_ card: MailCard) -> String {
        if let a = card.account { return MailInboxRules.line(a.displayName, limit: 40) }
        return card.message.accountID == MailSyncActor.manualAccountID || card.message.senderKind == .manual
            ? L.Mail.manualAccount : MailInboxRules.line(card.message.accountID, limit: 24)
    }

    static func symbol(_ card: MailCard) -> String {
        switch card.account?.kind {
        case .folder: return "folder"
        case .imap: return "server.rack"
        case nil: return "tray.and.arrow.down"
        }
    }
}

/// Sender name and address on one line (both untrusted, rendered verbatim). When the line is
/// short of room the address gives way first (middle-truncated), so the name stays readable.
/// `showsAddress` false (the inbox list): the name only, the address its tooltip.
struct MailSenderLine: View {
    let message: MailMessage
    var showsAddress = true

    var body: some View {
        let name = MailInboxRules.line(message.fromName, limit: 80)
        let address = MailInboxRules.line(message.fromAddress, limit: 120)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: name.isEmpty ? address : name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(name.isEmpty ? .middle : .tail)
                .layoutPriority(1)
                .help(address)
            if !name.isEmpty, showsAddress {
                Text(verbatim: "<\(address)>")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: name.isEmpty ? address : name + ", " + address))
    }
}

extension MailCard {
    /// Due date hint for today's date (nil when the triage found none).
    func dueHint(today: LocalDate = LocalDate.today()) -> MailInboxRules.DueHint? {
        MailInboxRules.dueHint(message, today: today)
    }

    var displaySubject: String {
        let s = MailInboxRules.line(message.subject, limit: 300)
        return s.isEmpty ? L.Mail.noSubject : s
    }

    /// Provider name for 「让 AI 分析」 texts: the triage provider, else the reading provider.
    func triageProviderName(_ state: AppState) -> String {
        let kind = state.engine.loadMailSettings().triageProvider ?? state.agentStatus.shownKind
        return kind.shortName
    }
}
