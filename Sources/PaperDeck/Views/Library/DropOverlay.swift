import SwiftUI
import PaperDeckCore

/// Full-window overlay while an importable drag hovers the library window:
/// 「松手添加 3 个 PDF」 (+ 「另有 2 个非 PDF 文件将被忽略」). Bound to the
/// DropHostingView's `dropState`; never intercepts the drop itself.
struct LibraryDropOverlay: View {
    let drop: DropTargetState?

    var body: some View {
        let targeted = drop?.isTargeted == true
        ZStack {
            if targeted, let drop {
                LibraryDropOverlayContent(summary: drop.summary)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: targeted)
        .allowsHitTesting(false)
    }
}

private struct LibraryDropOverlayContent: View {
    let summary: DropIntake.Summary

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).opacity(0.92)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                .padding(18)
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 54, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: summary.importable)
                Text(L.Shell.dropRelease(Self.what(summary)))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(L.Shell.dropHint).font(.callout).foregroundStyle(.secondary)
                if summary.otherFiles > 0 {
                    Label(L.Shell.dropIgnored(summary.otherFiles), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }

    /// `3 个 PDF`, `1 个文件夹`, `2 个链接` joined; promises and raw PDF data count as PDFs.
    static func what(_ s: DropIntake.Summary) -> String {
        var parts: [String] = []
        let pdfs = s.pdfFiles + s.promises + (s.pdfData ? 1 : 0)
        if pdfs > 0 { parts.append(L.Shell.nPDFs(pdfs)) }
        if s.folders > 0 { parts.append(L.Shell.nFolders(s.folders)) }
        if s.links > 0 { parts.append(L.Shell.nLinks(s.links)) }
        return parts.isEmpty ? L.Shell.nPDFs(0) : parts.joined(separator: L.Shell.listSeparator)
    }
}
