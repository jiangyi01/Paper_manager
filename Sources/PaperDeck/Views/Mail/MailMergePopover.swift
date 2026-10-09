import SwiftUI
import PaperDeckCore

/// 「合并到论文库」 / 「全部合并」 options (MAIL_DESIGN Part A §3 "Merge semantics"): priority, the
/// email's due date as a pinned DDL (pre-checked only when the triage is confident and the date
/// is not past — 「邮件中的日期已过」 otherwise), category and AI reading. Defaults come from the
/// sender rule (`MailMergeOptions.suggested`); nothing is applied until the user confirms.
///
/// Duplicates (Slice B3): when the row looks like a paper already in the library
/// (`Engine.mailDuplicateMatch`, from the row's metadata only), the match is shown *before*
/// merging with four answers — link to it, link and re-read it, use the email's version, add it
/// as a separate paper (`MailDupChoice`) — the suggested one preselected; the confirm button
/// applies the chosen one (`DedupeUIModel.resolveMail`). "Merge All" lists how many rows look
/// like library papers (identical ids are linked; the rest can be reviewed under Duplicates).
///
/// 「转换为 PDF 并合并」 (one document row, `convertMode`): the same options, titled for the
/// conversion, with what it does — converted on this Mac (nothing uploaded or sent to AI), figures
/// may not convert, the original is kept next to the PDF, and the possibly-unpublished hold.
/// No duplicate lookup before converting: the engine's import dedupes the PDF it makes.
struct MailMergePopover: View {
    let state: AppState
    let card: MailCard
    /// The rows this merge takes (one row, or the 「全部合并」 targets).
    let items: [MailItem]
    let onConfirm: (MailMergeOptions) -> Void
    let onCancel: () -> Void

    @State private var loaded = false
    @State private var priority: Priority = .normal
    @State private var pinDue = false
    @State private var category = ""
    @State private var readWithAI = true
    /// The library paper the one row looks like (nil: none, or several rows).
    @State private var match: MailDupMatch?
    @State private var dupChoice: MailDupChoice = .addSeparately
    /// "Merge All": how many rows look like library papers.
    @State private var matchCount = 0
    /// Renders: a match without an engine lookup.
    var fixtureMatch: MailDupMatch?

    /// The add-options (priority, category, AI reading) apply: no match, or "add separately".
    private var addsPaper: Bool { match == nil || dupChoice == .addSeparately }

    /// One document row converted on this Mac, then added.
    static func convertMode(_ items: [MailItem]) -> Bool {
        items.count == 1 && items.allSatisfy { MailInboxRules.actions($0).contains(.convertAndMerge) }
    }
    private var convertMode: Bool { Self.convertMode(items) }

    private var today: LocalDate { state.snapshot?.today.today ?? LocalDate.today() }
    private var due: MailInboxRules.DueHint? { card.dueHint(today: today) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let match {
                MailDuplicateSection(match: match, choice: $dupChoice)
                Divider()
                if !addsPaper {
                    Text(L.Dedupe.mailOptionsApplyToAdd).font(.caption).foregroundStyle(.secondary)
                }
            } else if matchCount > 0 {
                Label(L.Dedupe.mailMatches(matchCount), systemImage: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(L.Mail.priority).foregroundStyle(.secondary)
                    Picker(L.Mail.priority, selection: $priority) {
                        ForEach([Priority.low, .normal, .high], id: \.self) { p in
                            Text(L.Mail.priorityName(p)).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                GridRow {
                    Text(L.Mail.category).foregroundStyle(.secondary)
                    Picker(L.Mail.category, selection: $category) {
                        Text(L.Mail.categoryAuto).tag("")
                        ForEach(categoryNames, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
            .font(.callout)
            .disabled(!addsPaper)
            dueSection
                .disabled(!(addsPaper || dupChoice == .reread))
            Toggle(L.Mail.readWithAI(L.ai), isOn: $readWithAI)
                .font(.callout)
                .disabled(!addsPaper)
            notes
            HStack {
                if card.rule != nil {
                    Text(L.Mail.fromRule).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(L.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    if let match, let item = items.first {
                        state.dedupe.resolveMail(item, paperID: match.existingPaperID, choice: dupChoice, options: options)
                        onCancel()                          // done here: the popover just closes
                    } else {
                        onConfirm(options)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!loaded)
            }
        }
        .padding(16)
        .frame(width: match == nil ? 360 : 420)
        .task(id: card.id) { await load() }
    }

    private var confirmTitle: String {
        if convertMode { return L.Mail.convertConfirm }
        if match != nil { return L.Dedupe.mailConfirm(dupChoice) }
        return items.count > 1 ? L.Mail.confirmMany(items.count) : L.Mail.confirmOne
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(convertMode ? L.Mail.convertTitle : items.count > 1 ? L.Mail.mergeTitleMany(items.count) : L.Mail.mergeTitleOne)
                .font(.headline)
            if items.count == 1, let item = items.first {
                let title = MailDocumentInfo.isDocument(item)
                    ? (MailDocumentInfo.fileName(item) ?? "") : MailInboxRules.line(item.title, limit: 120)
                Text(verbatim: title.isEmpty ? L.Mail.untitled : title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(verbatim: card.displaySubject)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var dueSection: some View {
        if let due {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L.Mail.pinDue(SharedStrings.monthDay(due.date)), isOn: $pinDue)
                    .font(.callout)
                    .disabled(due.isPast)
                if due.isPast {
                    Label(L.Mail.duePast, systemImage: "calendar.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !due.confident {
                    Text(L.Mail.dueUncertain).font(.caption).foregroundStyle(.secondary)
                }
                if let evidence = due.evidence {
                    Text(verbatim: L.Mail.evidence(evidence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        let linking = items.contains { MailInboxRules.chip($0) == .inLibrary }
        if convertMode {
            VStack(alignment: .leading, spacing: 3) {
                Label(L.Mail.convertLocalNote, systemImage: "desktopcomputer")
                Label(L.Mail.figuresPlacementNote, systemImage: "photo.badge.exclamationmark")
                Label(L.Mail.keepOriginalNote, systemImage: "doc.on.doc")
                if MailDocumentInfo.possiblyUnpublished(card.message) {
                    Label(ImportAnnotation.unpublishedHoldText(L.lang), systemImage: "lock.shield")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if (readWithAI && items.count > IntakeActor.holdThreshold) || linking {
            VStack(alignment: .leading, spacing: 3) {
                if readWithAI && items.count > IntakeActor.holdThreshold {
                    Label(L.Mail.heldBatchNote, systemImage: "hand.raised")
                }
                if linking {
                    Label(L.Mail.linkNote, systemImage: "link")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var categoryNames: [String] {
        var names = (state.snapshot?.categories ?? []).map(\.category.name)
        if let d = card.rule?.defaultCategory?.trimmingCharacters(in: .whitespaces), !d.isEmpty, !names.contains(d) {
            names.insert(d, at: 0)
        }
        return names
    }

    private var options: MailMergeOptions {
        MailMergeOptions(priority: priority == .normal ? nil : priority,
                         pinDeadline: pinDue && due?.isPast == false ? due?.date : nil,
                         category: category.isEmpty ? nil : category,
                         readWithAI: readWithAI)
    }

    private func load() async {
        let s = await state.suggestedMergeOptions(for: card)
        priority = s.priority ?? .normal
        pinDue = s.pinDeadline != nil
        category = s.category ?? ""
        readWithAI = s.readWithAI
        guard DedupeUIModel.isAvailable else {
            loaded = true
            return
        }
        // One row: its question decides what the button does, so it comes first. A document is
        // converted first; the import dedupes the PDF it makes.
        if let fixtureMatch {
            match = fixtureMatch
        } else if convertMode {
            match = nil
        } else if items.count == 1, let item = items.first {
            match = await state.engine.mailDuplicateMatch(itemID: item.id)
        }
        if let match { dupChoice = match.defaultChoice }
        loaded = true
        // "Merge All": the count is only a note — the button doesn't wait for it.
        if items.count > 1 {
            var n = 0
            for item in items.prefix(Self.matchScanLimit) where await state.engine.mailDuplicateMatch(itemID: item.id) != nil {
                n += 1
            }
            matchCount = n
        }
    }

    /// "Merge All" looks this many rows up (each is one local lookup).
    static let matchScanLimit = 20
}

/// The duplicate question of one email row: what it looks like, why, and the four answers.
struct MailDuplicateSection: View {
    let match: MailDupMatch
    @Binding var choice: MailDupChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(L.Dedupe.mailLooksLike).font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "square.on.square").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: match.existing.title)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: match.headline).font(.caption).foregroundStyle(.secondary)
                if let line = match.versionLine {
                    Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                }
                if let line = match.historyLine {
                    Text(verbatim: line).font(.caption).foregroundStyle(.secondary)
                }
                if !match.evidence.isEmpty {
                    Text(verbatim: match.evidence.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 24)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(match.choices, id: \.self) { c in
                    Button { choice = c } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: choice == c ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice == c ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L.Dedupe.mailChoice(c)).font(.callout.weight(choice == c ? .semibold : .regular))
                                Text(L.Dedupe.mailChoiceDetail(c, deleted: match.existing.deletedAt != nil))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(choice == c ? Color.accentColor.opacity(0.08) : .clear))
                    .accessibilityAddTraits(choice == c ? [.isSelected] : [])
                }
            }
        }
    }
}
