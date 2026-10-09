import SwiftUI
import PaperDeckCore

/// The per-row drop box of a row that needs a PDF: 「把下载好的 PDF 拖到这里」 (a dashed box beside
/// the row's buttons), 「松手作为这篇的 PDF」 while a single PDF hovers the row. The drop itself is
/// received by the window's `DropHostingView` (file promises need AppKit) through
/// `DropTargetRegistry`; clicking the box is 「选择 PDF…」 (the keyboard / accessibility path).
struct MailDropBox: View {
    let targeted: Bool
    let onChoose: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 5) {
                Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.bounce, value: targeted)
                Text(targeted ? L.Mail.dropRelease : L.Mail.dropHere)
                    .font(.system(size: 11, weight: targeted ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(targeted ? 0.14 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its natural width where there is room; the caption truncates in a very narrow column
        // (the row's flow layout offers it the line's width) instead of overflowing the row.
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.12), value: targeted)
        .help(L.Mail.dropHere + " · " + L.Mail.choosePDF)
        .accessibilityLabel(L.Mail.choosePDF)
        .accessibilityHint(L.Mail.dropHere)
    }
}

/// Outline + caption drawn over a row or card while it is the drop target.
struct MailDropHighlight: ViewModifier {
    let active: Bool
    let caption: String
    var cornerRadius: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.07)))
                        .overlay(alignment: .topTrailing) {
                            Label(caption, systemImage: "arrow.down.doc.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(6)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

extension View {
    func mailDropHighlight(_ active: Bool, caption: String, cornerRadius: CGFloat = 9) -> some View {
        modifier(MailDropHighlight(active: active, caption: caption, cornerRadius: cornerRadius))
    }
}

/// The library window's drop layer: nothing while a Mail row / card is targeted (it highlights
/// itself), 「松手导入 N 封邮件」 for email drags, otherwise the regular 「松手添加 N 个 PDF」 overlay.
struct MailAwareDropOverlay: View {
    let drop: DropTargetState?

    var body: some View {
        let mail = drop?.mailFiles ?? 0
        Group {
            if drop?.target != nil {
                Color.clear
            } else if mail > 0, let drop, drop.isTargeted {
                MailDropOverlayContent(emails: mail,
                                       pdfs: drop.summary.pdfFiles + drop.summary.promises + (drop.summary.pdfData ? 1 : 0))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LibraryDropOverlay(drop: drop)
            }
        }
        .animation(.easeOut(duration: 0.16), value: drop?.isTargeted == true)
        .allowsHitTesting(false)
    }
}

private struct MailDropOverlayContent: View {
    let emails: Int
    let pdfs: Int

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).opacity(0.92)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                .padding(18)
            VStack(spacing: 14) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 54, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text(L.Mail.dropEmails(emails))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(L.Mail.dropEmailsHint).font(.callout).foregroundStyle(.secondary)
                if pdfs > 0 {
                    Label(L.Mail.dropAlsoPDFs(pdfs), systemImage: "doc.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}
