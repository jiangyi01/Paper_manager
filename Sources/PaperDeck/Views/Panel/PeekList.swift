import SwiftUI
import PaperDeckCore

/// Hover preview of today's set in the floating panel (280 pt wide).
/// Pending decision / error toasts sit on top so they are never out of reach;
/// 「📨 3 封邮件待处理」 under the header opens Library ▸ 邮件.
struct PeekList: View {
    let state: AppState
    var maxRows = 6
    var onOpenPaper: (String) -> Void
    var onOpenToday: () -> Void
    /// Nil → `state.router.showMail(nil)` (the panel collapses when the pointer leaves).
    var onOpenMail: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.toasts.isEmpty {
                ToastStack(state: state, maxVisible: 2)
            }
            if let snapshot = state.snapshot {
                content(snapshot)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.peekLoading).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func content(_ snapshot: LibrarySnapshot) -> some View {
        let plan = snapshot.today
        let lang = L.lang
        Button(action: onOpenToday) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(plan.isEmpty ? L.peekNothing : L.peekHeader(count: plan.count, minutes: plan.todayMinutes))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !plan.overdue.isEmpty {
                    Label(SharedStrings.Widget.overdueCount(plan.overdue.count, lang),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        mailLine

        if !plan.isEmpty {
            let rows = snapshot.todayRows
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows.prefix(maxRows)) { row in
                    PeekRow(row: row, today: plan.today, lang: lang)
                        .onTapGesture { onOpenPaper(row.id) }
                }
                if rows.count > maxRows {
                    Text(SharedStrings.Reminder.lineMore(rows.count - maxRows, lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                        .padding(.top, 2)
                }
            }
        }

        Divider()
        HStack(spacing: 8) {
            Text(SharedStrings.backlogLine(total: plan.backlogTotal, unscheduled: plan.unscheduled, lang))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(L.peekOpenToday, action: onOpenToday)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}

extension PeekList {
    /// 「📨 3 封邮件待处理（1 封请求）」 — only while mail is pending.
    @ViewBuilder var mailLine: some View {
        if let counts = state.mailSnapshot?.counts,
           let line = L.Mail.peekLine(total: counts.pending, requests: counts.requests) {
            Button {
                if let onOpenMail { onOpenMail() } else { state.router.showMail(nil) }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: line)
                        .font(.system(size: 12, weight: counts.requests > 0 ? .semibold : .medium))
                        .foregroundStyle(counts.requests > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.Mail.peekOpenMail)
            .accessibilityLabel(line)
            .accessibilityHint(L.Mail.peekOpenMail)
        }
    }
}

/// `[ring] Title (2 lines)` over `[DDL chip] 今天 25′ 2/6`.
private struct PeekRow: View {
    let row: PaperRow
    let today: LocalDate
    let lang: UILang

    var body: some View {
        let paper = row.paper
        HStack(alignment: .top, spacing: 8) {
            ProgressRing(done: row.doneCount, total: row.totalCount)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    DDLChip(spec: chip)
                    if let minutes = row.minutesToday, minutes > 0 {
                        Text(L.peekMinutesToday(minutes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if row.totalCount > 0 {
                        Text("\(row.doneCount)/\(row.totalCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var chip: ChipSpec {
        let p = row.paper
        return DeadlineLabel.chip(deadline: p.scheduleMode == .none ? nil : p.deadline,
                                  done: p.status == .done, doneAt: p.doneAt.map { LocalDate($0) },
                                  pinned: p.scheduleMode == .pinned,
                                  provisional: p.provisional && p.scheduleMode == .auto,
                                  atRisk: row.atRisk, today: today, lang: lang)
    }
}
