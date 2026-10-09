import AppKit
import SwiftUI
import PaperDeckCore

/// Document attachments and share links (the lab-manuscript fix) — app-side checks of
/// `--selftest app-rules`:
/// - display rules (`MailDocumentInfo`): kinds by extension, file names, the meta line, services
///   from Core's keys only, what a share URL points at (Core's kind first), the share row's title
///   and meta line, the possibly-unpublished rule, the drop box's caption;
/// - chips: 附件文档 like 附件 PDF, 需导出 / 共享链接 dashed like 需要 PDF, 转换中 like 下载中;
///   every new string non-empty and different in en and zh;
/// - 「转换为 PDF 并合并」 opens the convert popover for one document row only;
/// - 「打开」 (`MailDocumentOpen`): document types inside the attachment folder only (no app,
///   script, web page, folder, symlink out of it, prefix look-alike folder); marked as downloaded;
/// - drawn rows (read back with on-device text recognition): the document row shows its buttons
///   and notes, the slides row and the share row their drop-box captions, a converting row its
///   progress line, a failed one its reason and the export drop box, a converted row what it kept;
/// - `AppState.convertMailDocument` (a .docx made in memory, then a file that isn't one) marks the
///   row converting until the engine answers, then posts the success toast (「查看」 the new paper)
///   or the failure hint; `openMailDocument` warns about a missing file and opens nothing.
/// Synthetic rows, a scratch engine (never started: no sync, no AI, no network), scratch defaults.
extension SelfTestAppRules {
    static func runDocs(scratch: URL, _ c: Checker) async {
        let saved = LangStore.shared.lang
        defer { LangStore.shared.lang = saved }
        docsDisplayRules(c)
        docsStrings(c)
        docsChips(c)
        docsOpenGuard(scratch: scratch, c)
        docsPreview(c)
        LangStore.shared.lang = saved
        await docsDrawnAndActions(scratch: scratch, c)
    }

    // MARK: Display rules

    /// A row as Core stores it (`documentFileName` / `documentKind` / `shareHost`; `pdfBytes` = size).
    static func docsItem(_ origin: MailItemOrigin, title: String? = nil, file: String? = nil, kind: String? = nil,
                         bytes: Int64? = nil, url: String? = nil, original: String? = nil, host: String? = nil,
                         shareHost: String? = nil, state: MailPDFState, status: MailItemStatus = .pending) -> MailItem {
        MailItem(ord: 0, cand: "c1", origin: origin, title: title, url: url, urlOriginal: original, host: host,
                 pdfState: state, pdfBytes: bytes, status: status, documentFileName: file, documentKind: kind,
                 shareHost: shareHost, documentPath: file.map { "m/" + $0 })
    }

    private static func docsDisplayRules(_ c: Checker) {
        typealias I = MailDocumentInfo
        let kinds: [(String, I.Kind)] = [("docx", .word), ("DOC", .word), ("rtf", .richText), ("odt", .openDocument),
                                         ("pages", .pages), ("pptx", .powerPoint), ("ppt", .powerPoint), ("odp", .powerPoint),
                                         ("key", .keynote), ("xlsx", .excel), ("numbers", .numbers),
                                         ("pdf", .other), ("", .other), ("exe", .other)]
        let wrong = kinds.filter { I.kind(ext: $0.0) != $0.1 }
        c.check("docs: document kinds by extension", wrong.isEmpty, ["wrong": wrong.map(\.0)])

        let named = docsItem(.document, title: "Smith lab manuscript v3", file: "Smith_lab_manuscript_v3.docx", kind: "docx",
                             state: .convertible)
        let kindOnly = docsItem(.document, title: "Lab meeting", file: "Lab_meeting", kind: "PPTX", state: .openOnly)
        let titleOnly = docsItem(.document, title: "Draft", state: .convertible)
        let hostile = docsItem(.document, title: "Draft", file: "Draft\u{202E}xcod.exe\u{200B}.docx", kind: "do<c", state: .convertible)
        c.check("docs: the file name, else the title; the extension from Core's kind, else the name",
                I.fileName(named) == "Smith_lab_manuscript_v3.docx" && I.ext(named) == "docx"
                    && I.ext(kindOnly) == "pptx" && I.fileName(titleOnly) == "Draft" && I.ext(titleOnly) == nil,
                ["named": I.fileName(named), "kindOnly": I.ext(kindOnly)])
        let shown = I.fileName(hostile) ?? ""
        c.check("docs: a file name is inert (no bidi / zero-width characters), a strange kind is ignored",
                !shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B } && I.ext(hostile) == "docx",
                ["shown": shown, "ext": I.ext(hostile)])

        let providers: [(String?, I.Provider?)] = [
            ("sharepoint.com", .sharePoint), ("onedrive.live.com", .oneDrive), ("box.com", .box),
            ("drive.google.com", .googleDrive), ("docs.google.com", .googleDrive), ("dropbox.com", .dropbox),
            ("icloud.com", .iCloud), ("evil-sharepoint.com", nil), ("contoso-my.sharepoint.com", nil), (nil, nil), ("", nil),
        ]
        let badProviders = providers.filter { I.Provider(key: $0.0) != $0.1 }
        c.check("docs: share services from Core's keys only", badProviders.isEmpty,
                ["wrong": badProviders.map { $0.0 ?? "nil" }])

        let shared: [(String, I.Provider?, I.SharedKind)] = [
            ("https://contoso-my.sharepoint.com/:w:/g/personal/x/EaB?e=1", .sharePoint, .word),
            ("https://contoso-my.sharepoint.com/:p:/g/personal/x/EaB", .sharePoint, .powerPoint),
            ("https://contoso.sharepoint.com/:x:/s/lab/EaB", .sharePoint, .excel),
            ("https://contoso.sharepoint.com/:b:/s/lab/EaB", .sharePoint, .pdf),
            ("https://contoso-my.sharepoint.com/:f:/g/personal/x/EkF", .sharePoint, .folder),
            ("https://onedrive.live.com/:w:/r/x", .oneDrive, .word),
            ("https://docs.google.com/document/d/1AbC/edit", .googleDrive, .googleDoc),
            ("https://docs.google.com/presentation/d/1AbC/edit", .googleDrive, .googleSlides),
            ("https://docs.google.com/spreadsheets/d/1AbC/edit", .googleDrive, .googleSheet),
            ("https://drive.google.com/drive/folders/1AbC", .googleDrive, .folder),
            ("https://drive.google.com/file/d/1AbC/view", .googleDrive, .file),
            ("https://www.dropbox.com/scl/fi/abc/Manuscript_v3.docx?rlkey=x&dl=0", .dropbox, .word),
            ("https://app.box.com/s/abc123", .box, .file),
            // A SharePoint code on another service means nothing.
            ("https://example.org/:w:/x", nil, .file),
        ]
        let badShared = shared.filter { I.sharedKind(url: URL(string: $0.0), provider: $0.1) != $0.2 }
        c.check("docs: what a share URL points at", badShared.isEmpty, ["wrong": badShared.map(\.0)])
        let toldByCore = docsItem(.shareLink, kind: "pptx", url: "https://contoso.sharepoint.com/:w:/s/x/E",
                                  shareHost: "sharepoint.com", state: .needsPDF)
        c.check("docs: Core's kind of a share link wins over the URL's hints", I.sharedKind(toldByCore) == .powerPoint)

        // The share row's title: the unwrapped URL decides (the Safe Links original is only for opening).
        let wrapped = "https://nam10.safelinks.protection.outlook.com/?url=https%3A%2F%2Fcontoso-my.sharepoint.com%2F%3Ap%3A%2Fg%2Fx&data=05"
        let share = docsItem(.shareLink, url: "https://contoso-my.sharepoint.com/:w:/g/personal/x/EaB?e=1", original: wrapped,
                             host: "contoso-my.sharepoint.com", shareHost: "sharepoint.com", state: .needsPDF)
        let dropbox = docsItem(.shareLink, url: "https://www.dropbox.com/scl/fi/abc/Lab%20draft.docx?dl=0",
                               host: "www.dropbox.com", shareHost: "dropbox.com", state: .needsPDF)
        for lang in UILang.allCases {
            LangStore.shared.lang = lang
            let title = I.shareTitle(share)
            let expected = lang == .zh ? "共享的 Word 文档 · SharePoint" : "Shared Word document · SharePoint"
            c.check("docs (\(lang.rawValue)): a share row without a name says what and where",
                    title == expected && I.shareMeta(share) == "contoso-my.sharepoint.com", ["title": title, "meta": I.shareMeta(share)])
            c.check("docs (\(lang.rawValue)): a share row with a file name in its URL shows it, kind and host below",
                    I.shareTitle(dropbox) == "Lab draft.docx"
                        && I.shareMeta(dropbox) == L.Mail.sharedDocument(.word, provider: .dropbox) + " · www.dropbox.com",
                    ["title": I.shareTitle(dropbox), "meta": I.shareMeta(dropbox)])
            let doc = docsItem(.document, title: "Smith lab manuscript v3", file: "Smith_lab_manuscript_v3.docx", kind: "docx",
                               bytes: 7_549_747, state: .convertible)
            let meta = I.documentMeta(doc)
            let kindText = lang == .zh ? "附件：Word 稿件" : "Word manuscript attached"
            c.check("docs (\(lang.rawValue)): the document meta line — kind, extension, size",
                    meta == [kindText, "docx", L.bytes(7_549_747)].joined(separator: " · "), ["meta": meta])
        }

        let message = { (kind: SenderKind, subject: String) in
            MailMessage(accountID: "manual", internetMessageID: "<docs@x>", fromAddress: "a@lab.example.edu",
                        senderKind: kind, subject: subject, receivedAt: Date())
        }
        let review = message(.alert, "Invitation to review manuscript NCOMMS-26-01234")
        c.check("docs: documents from a person, an advisor or a dropped email are possibly unpublished",
                I.possiblyUnpublished(message(.advisor, "Draft")) && I.possiblyUnpublished(message(.person, "Draft"))
                    && I.possiblyUnpublished(message(.manual, "Draft"))
                    && !I.possiblyUnpublished(message(.alert, "New results in your field"))
                    && I.possiblyUnpublished(review) == MailHeuristics.isConfidential(review))

        let link = docsItem(.link, url: "https://www.cell.com/x", state: .needsPDF)
        let tooLarge = docsItem(.document, file: "Huge.docx", kind: "docx", state: .needsPDF)
        let shareRow = docsItem(.shareLink, url: "https://contoso.sharepoint.com/:w:/s/x/E", shareHost: "sharepoint.com",
                                state: .needsPDF)
        let slidesRow = docsItem(.document, file: "b.pptx", kind: "pptx", state: .openOnly)
        func caption(_ i: MailItem) -> String { I.dropCaption(i, chip: MailInboxRules.chip(i)) }
        func detail(_ i: MailItem) -> String? { I.dropDetail(i, chip: MailInboxRules.chip(i)) }
        c.check("docs: drop-box captions per row kind (a document too large to store: export it)",
                caption(slidesRow) == L.Mail.dropExported && caption(tooLarge) == L.Mail.dropExported
                    && caption(shareRow) == L.Mail.dropShared && caption(link) == L.Mail.dropHere
                    && detail(slidesRow) == L.Mail.dropExportedHelp && detail(shareRow) == L.Mail.dropSharedHelp
                    && detail(link) == nil)

        // 「转换为 PDF 并合并」 → the convert popover only for one convertible document row.
        let convertible = docsItem(.document, file: "a.docx", kind: "docx", state: .convertible)
        let slides = docsItem(.document, file: "b.pptx", kind: "pptx", state: .openOnly)
        let pdf = docsItem(.attachment, title: "Paper", state: .hasPDF)
        c.check("docs: the convert popover is for one convertible document row",
                MailMergePopover.convertMode([convertible]) && !MailMergePopover.convertMode([convertible, convertible])
                    && !MailMergePopover.convertMode([slides]) && !MailMergePopover.convertMode([pdf])
                    && !MailMergePopover.convertMode([]))
    }

    // MARK: Strings

    private static func docsStrings(_ c: Checker) {
        func both(_ f: () -> String) -> (String, String) {
            LangStore.shared.lang = .en
            let en = f()
            LangStore.shared.lang = .zh
            let zh = f()
            return (en, zh)
        }
        var texts: [String: () -> String] = [
            "chipConverting": { L.Mail.chipConverting }, "convertAndAdd": { L.Mail.convertAndAdd },
            "convertHelp": { L.Mail.convertHelp }, "openDocument": { L.Mail.openDocument },
            "openDocumentHelp": { L.Mail.openDocumentHelp }, "figuresNote": { L.Mail.figuresNote },
            "signInNeeded": { L.Mail.signInNeeded }, "converting": { L.Mail.converting },
            "keptOriginal": { L.Mail.keptOriginal("docx") }, "keptOriginalNil": { L.Mail.keptOriginal(nil) },
            "dropExported": { L.Mail.dropExported }, "dropShared": { L.Mail.dropShared },
            "dropSharedHelp": { L.Mail.dropSharedHelp }, "dropExportedHelp": { L.Mail.dropExportedHelp },
            "convertTitle": { L.Mail.convertTitle }, "convertConfirm": { L.Mail.convertConfirm },
            "convertLocalNote": { L.Mail.convertLocalNote }, "keepOriginalNote": { L.Mail.keepOriginalNote },
            "figuresPlacementNote": { L.Mail.figuresPlacementNote },
            "converted": { L.Mail.converted("x.docx") }, "convertFailed": { L.Mail.convertFailed },
            "documentMissing": { L.Mail.documentMissing }, "documentRefused": { L.Mail.documentRefused },
            "copyRowLink": { L.Mail.copyRowLink },
        ]
        for k in MailDocumentInfo.Kind.allCases {
            texts["kind.\(k.rawValue)"] = { L.Mail.documentKind(k) }
            texts["attached.\(k.rawValue)"] = { L.Mail.documentAttached(k) }
        }
        for k in MailDocumentInfo.SharedKind.allCases {
            texts["shared.\(k.rawValue)"] = { L.Mail.sharedDocument(k, provider: nil) }
        }
        for chip in [MailInboxRules.ItemChip.convertible, .openOnly, .shareLink] {
            texts["chip.\(chip.rawValue)"] = { L.Mail.chip(chip) }
        }
        let bad = texts.keys.sorted().filter { key in
            let (en, zh) = both(texts[key]!)
            return en.isEmpty || zh.isEmpty || en == zh
        }
        c.check("docs: every new string exists in en and zh, and they differ", bad.isEmpty, ["bad": bad])
        let chipTexts = MailInboxRules.ItemChip.allCases.map { L.Mail.chip($0) }
        c.check("docs: chip texts are distinct", Set(chipTexts).count == chipTexts.count && !chipTexts.contains(L.Mail.chipConverting))
    }

    // MARK: Chips

    private static func docsChips(_ c: Checker) {
        typealias V = MailItemChipView
        c.check("docs: 附件文档 looks like 附件 PDF (blue, solid)",
                V.hue(.convertible) == V.hue(.attachment) && !V.dashed(.convertible))
        c.check("docs: 需导出 and 共享链接 look like 需要 PDF (orange, dashed)",
                V.hue(.openOnly) == V.hue(.needsPDF) && V.hue(.shareLink) == V.hue(.needsPDF)
                    && V.dashed(.openOnly) && V.dashed(.shareLink) && V.dashed(.needsPDF) && !V.dashed(.attachment))
        c.check("docs: 转换中 looks like 下载中", V.convertingHue == V.hue(.downloading))
        let symbols = MailInboxRules.ItemChip.allCases.map(V.symbol)
        c.check("docs: every chip has its own glyph", Set(symbols).count == symbols.count && !symbols.contains(V.convertingSymbol))
        // The rows these chips sit on (Core's rules for the new states).
        let doc = docsItem(.document, file: "a.docx", kind: "docx", state: .convertible)
        let slides = docsItem(.document, file: "b.pptx", kind: "pptx", state: .openOnly)
        let share = docsItem(.shareLink, url: "https://contoso.sharepoint.com/:w:/s/x/E", host: "contoso.sharepoint.com",
                             shareHost: "sharepoint.com", state: .needsPDF)
        let a = MailInboxRules.actions
        c.check("docs: a convertible document offers 转换 + 打开, no drop box",
                MailInboxRules.chip(doc) == .convertible && a(doc).contains(.convertAndMerge) && a(doc).contains(.openDocument)
                    && !a(doc).contains(.dropBox) && !a(doc).contains(.openLink))
        c.check("docs: slides offer 打开 + the drop box, no conversion",
                MailInboxRules.chip(slides) == .openOnly && a(slides).contains(.openDocument) && a(slides).contains(.dropBox)
                    && !a(slides).contains(.convertAndMerge))
        c.check("docs: a share link offers 打开链接 + the drop box, never a download",
                MailInboxRules.chip(share) == .shareLink && a(share).contains(.openLink) && a(share).contains(.dropBox)
                    && !a(share).contains(.download) && !a(share).contains(.downloadAndMerge)
                    && !a(share).contains(.convertAndMerge))
    }

    // MARK: Settings ▸ Mail's preview (`--mail-dry-run`, the AI sample)

    /// The lab-manuscript email (an advisor's FYI with a .docx and Safe Links to SharePoint) in
    /// the triage preview: kept in 待处理 as a sync would keep it — even when FYI isn't a kept
    /// kind — with a convertible document row (its file name) and shared-file rows (the service,
    /// the Safe Links original kept for opening).
    private static func docsPreview(_ c: Checker) {
        let rule = SenderRule(id: "selftest-pi", pattern: "pi@lab.example.edu", label: "Prof. Smith", kind: .advisor)
        var settings = MailSettings(senders: [rule])
        settings.criteria.keepKinds = [.advisorRequest, .journalClub, .alertDigest]
        let header = MailHeader(ref: "docs-preview", internetMessageID: "<docs-preview@lab.example.edu>",
                                fromAddress: "pi@lab.example.edu", fromName: "Prof. Smith",
                                subject: "Manuscript draft", receivedAt: Date())
        let target = "https://contoso-my.sharepoint.com/:w:/g/personal/pi_lab_example_edu/EaBcD123?e=x1"
        let wrapped = "https://nam10.safelinks.protection.outlook.com/?url="
            + (target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target) + "&data=05%7C02&reserved=0"
        let text = "Hi all,\n\nFYI, the current draft of our manuscript is attached; the shared copy is here:\n\(wrapped)\n\nJ.\n"
        let attributed = NSAttributedString(string: "A synthetic manuscript.")
        let docx = (try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])) ?? Data()
        let attachment = MailAttachment(filename: "Lab_manuscript_v3.docx",
                                        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                        isInline: false, data: docx, sizeBytes: docx.count)
        let content = MailContent(header: header, plainText: text, html: nil, attachments: [attachment])
        let r = MailTriagePreview.run(content: content, rule: rule, settings: settings, engineSettings: EngineSettings(lang: .en),
                                      categories: [], frequentTags: [], now: Date(), calendar: .current)
        let doc = r.items.first { $0.origin == .document }
        let share = r.items.first { $0.origin == .shareLink }
        c.check("docs preview: an advisor's manuscript email stays pending (FYI not kept)",
                r.syncedState == .pending, ["kind": r.heuristic.requestKind.rawValue, "state": r.syncedState.rawValue])
        c.check("docs preview: the .docx is a convertible document row with its file name",
                doc?.pdfState == .convertible && doc?.documentFileName == "Lab_manuscript_v3.docx" && doc?.documentKind == "docx",
                ["state": doc?.pdfState.rawValue, "name": doc?.documentFileName])
        c.check("docs preview: the Safe Link is a shared-file row (service known, original kept for opening)",
                share?.shareHost == "sharepoint.com" && share?.pdfState == .needsPDF && share?.urlOriginal == wrapped
                    && URL(string: share?.url ?? "")?.host == "contoso-my.sharepoint.com",
                ["host": share?.shareHost, "state": share?.pdfState.rawValue, "url": share?.url])
    }

    // MARK: 「打开」

    private static func docsOpenGuard(scratch: URL, _ c: Checker) {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("docs-open/mail/files", isDirectory: true)
        let card = root.appendingPathComponent("m1", isDirectory: true)
        let outside = scratch.appendingPathComponent("docs-open/elsewhere", isDirectory: true)
        let lookalike = scratch.appendingPathComponent("docs-open/mail/files-evil", isDirectory: true)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? fm.createDirectory(at: lookalike, withIntermediateDirectories: true)
        func file(_ dir: URL, _ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            try? Data("x".utf8).write(to: url)
            return url
        }
        let docx = file(card, "1.docx")
        let key = file(card, "2.KEY")
        let app = card.appendingPathComponent("3.app", isDirectory: true)
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        let html = file(card, "4.html")
        let command = file(card, "5.command")
        let folderDocx = card.appendingPathComponent("6.docx", isDirectory: true)
        try? fm.createDirectory(at: folderDocx, withIntermediateDirectories: true)
        let away = file(outside, "7.docx")
        let link = card.appendingPathComponent("8.docx")
        try? fm.createSymbolicLink(at: link, withDestinationURL: away)
        let evil = file(lookalike, "9.docx")
        let missing = card.appendingPathComponent("10.docx")
        let linkToApp = card.appendingPathComponent("11.docx")
        try? fm.createSymbolicLink(at: linkToApp, withDestinationURL: command)
        let may = { (u: URL) in MailDocumentOpen.mayOpen(u, root: root) }
        c.check("docs open: documents inside the attachment folder open", may(docx) && may(key))
        c.check("docs open: never an app, a web page, a script or a folder",
                !may(app) && !may(html) && !may(command) && !may(folderDocx))
        c.check("docs open: never a file outside the folder, through a symlink, or in a look-alike folder",
                !may(away) && !may(link) && !may(evil) && !may(linkToApp))
        c.check("docs open: a missing file is refused", !may(missing))
        let marked = MailDocumentOpen.markDownloaded(docx)
        let props = (try? docx.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        c.check("docs open: the attachment is marked as downloaded before it opens",
                marked && props?[kLSQuarantineAgentNameKey as String] as? String == "PaperDeck"
                    && MailDocumentOpen.markDownloaded(docx))
    }

    // MARK: Drawn cards and the app's actions

    private static func docsDrawnAndActions(scratch: URL, _ c: Checker) async {
        let lang = LangStore.shared.lang
        let root = scratch.appendingPathComponent("docs-drawn", isDirectory: true)
        guard let engine = try? await mailEngine(root, lang: Shared(lang), mail: MailSettings(), sources: [:]) else {
            c.check("docs drawn: engine fixture", false)
            return
        }
        let suite = scratch.appendingPathComponent("defaults-docs/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else {
            c.check("docs drawn: scratch defaults", false)
            await close(engine)
            return
        }
        let savedProvider = LangStore.shared.provider
        let store = SettingsStore(defaults: defaults)
        store.language = lang
        let state = AppState(engine: engine, settings: store)
        let card = MailDocumentRenders.demoCard(state: state)
        func squeezed(_ lines: [String]) -> String { lines.joined().filter { !$0.isWhitespace }.lowercased() }
        func has(_ lines: [String], _ text: String) -> Bool {
            squeezed(lines).contains(text.filter { !$0.isWhitespace }.lowercased())
        }
        // Fragments text recognition keeps reliably (words, not punctuation).
        let zh = lang == .zh
        let figures = zh ? "需要时请打开原文件" : "Figures may not convert"
        let convert = zh ? "转换为PDF" : "Convert to PDF"           // the button (OCR misreads 并)
        let unpublished = zh ? "可能是未发表稿件" : "Possibly unpublished"
        let exportDrop = zh ? "导出为PDF后拖到这里" : "Export as PDF and drop it here"
        let sharedDrop = zh ? "把PDF拖到这里" : "Download it, then drop the PDF here"   // OCR misreads 下载 now and then
        let shareTitle = zh ? "共享的Word文档" : "Shared Word document"
        let progress = zh ? "正在本机转换为PDF" : "Converting to PDF on this Mac"
        let kept = zh ? "文件随论文保存" : "is kept with the paper"

        let signIn = zh ? "不会自动下载共享链接" : "Sign-in needed"
        let failure = zh ? "无法读取这个文档" : "This document couldn't be read"
        // One row at a time (text recognition reads a single row reliably).
        func row(_ item: MailItem, in c: MailCard? = nil) async -> [String] {
            await drawnText(MailItemRow(state: state, card: c ?? card, item: item), width: 820)
        }
        let doc = card.items[0], share = card.items[1], slides = card.items[2]
        let docLines = await row(doc)
        c.check("docs drawn (\(lang.rawValue)): the document row shows Convert & Add, Open and its notes",
                has(docLines, convert) && has(docLines, L.Mail.openDocument) && has(docLines, figures)
                    && has(docLines, unpublished) && has(docLines, "Smith_lab_manuscript_v3.docx")
                    && !has(docLines, exportDrop), ["drawn": docLines])
        let shareLines = await row(share)
        c.check("docs drawn (\(lang.rawValue)): the share row shows its title, Open Link, sign-in and its drop box",
                has(shareLines, shareTitle) && has(shareLines, L.Mail.openLink) && has(shareLines, signIn)
                    && has(shareLines, sharedDrop) && !has(shareLines, convert), ["drawn": shareLines])
        let slideLines = await row(slides)
        c.check("docs drawn (\(lang.rawValue)): the slides row shows Open and its export drop box, no conversion",
                has(slideLines, L.Mail.openDocument) && has(slideLines, exportDrop) && has(slideLines, unpublished)
                    && !has(slideLines, convert) && !has(slideLines, figures), ["drawn": slideLines])

        MailDocumentActivity.shared.begin(doc.id)
        let converting = await row(doc)
        MailDocumentActivity.shared.end(doc.id)
        c.check("docs drawn (\(lang.rawValue)): a converting row shows its progress line and chip",
                has(converting, progress) && has(converting, L.Mail.chipConverting), ["drawn": converting])

        var failedRow = doc
        failedRow.downloadError = lang == .zh ? "无法读取这个文档（可能已加密或已损坏）"
                                              : "This document couldn't be read (it may be protected or damaged)"
        let failedLines = await row(failedRow)
        c.check("docs drawn (\(lang.rawValue)): a failed conversion says why, offers it again and the export drop box",
                has(failedLines, failure) && has(failedLines, convert) && has(failedLines, exportDrop),
                ["drawn": failedLines])

        var convertedRow = doc
        convertedRow.status = .merged
        convertedRow.pdfState = .inLibrary
        convertedRow.paperID = "p"
        convertedRow.documentPath = nil
        let done = await row(convertedRow)
        c.check("docs drawn (\(lang.rawValue)): a converted row says what it kept, no conversion button",
                has(done, kept) && has(done, L.Mail.openCard) && !has(done, convert)
                    && !has(done, figures), ["drawn": done])
        // A merged row whose original was never stored (too large): nothing was kept, so it says nothing.
        var notStored = convertedRow
        notStored.documentSHA256 = nil
        c.check("docs: only a row whose original was stored says it was kept",
                MailDocumentInfo.keptOriginal(convertedRow) && !MailDocumentInfo.keptOriginal(notStored)
                    && !MailDocumentInfo.keptOriginal(doc))

        // The card in the scratch library, its .docx stored (made in memory), the slides' copy gone.
        var storeError: String?
        let stored: (MailMessage, [MailItem])?
        do { stored = try await engine.db.insertMailMessage(card.message, items: card.items) } catch {
            stored = nil
            storeError = String(describing: error)
        }
        let text = NSAttributedString(string: "A synthetic manuscript.\n\nResults paragraph.")
        let docxData = try? text.data(from: NSRange(location: 0, length: text.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        if let path = doc.documentPath, let docxData {
            let url = engine.paths.mailFiles.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? docxData.write(to: url)
        }
        c.check("docs action: fixture card stored", stored?.1.count == card.items.count && docxData != nil,
                ["error": storeError, "docx": docxData?.count])

        // 「转换为 PDF 并合并」: converting until the engine answers, then one toast — 「已转换为 PDF
        // 并合并」 with 「查看」 opening the new paper; the row is merged.
        state.convertMailDocument(doc, options: MailMergeOptions(readWithAI: false))
        let began = MailDocumentActivity.shared.isConverting(doc.id) && state.mailBusy.contains(doc.id)
        state.convertMailDocument(doc, options: MailMergeOptions(readWithAI: false))   // a second click: ignored
        let ended = await eventually(20) { !MailDocumentActivity.shared.isConverting(doc.id) && !state.mailBusy.contains(doc.id) }
        let row = try? await engine.db.mailItem(id: doc.id)
        let toasts = state.toasts.filter { $0.id.hasPrefix("mail-convert") }
        let paperID = row?.paperID ?? "-"
        c.check("docs action: converting while the engine works, then one success toast opening the paper",
                began && ended && row?.status == .merged && toasts.count == 1 && toasts[0].id == "mail-converted-\(doc.id)"
                    && toasts[0].kind == .success && toasts[0].buttons.map(\.action) == [.openPaper(id: paperID)],
                ["toasts": state.toasts.map { "\($0.id): \($0.message)" }, "began": began, "ended": ended,
                 "status": row?.status.rawValue])

        // A document that isn't really one: the failure toast, the row keeps waiting with its reason.
        var broken = card.message
        broken.id = "b0c5d0c5-0000-4000-8000-0000000b0c5e"
        broken.internetMessageID = "<render-docs-broken@example.edu>"
        var brokenDoc = doc
        brokenDoc.id = "b0c5d0c5-0001-4000-8000-0000000b0c5e"
        brokenDoc.documentPath = broken.id + "/1.docx"
        brokenDoc.documentSHA256 = String(repeating: "b", count: 64)   // another file (the same one would link)
        let brokenStored = try? await engine.db.insertMailMessage(broken, items: [brokenDoc])
        let brokenURL = engine.paths.mailFiles.appendingPathComponent(broken.id + "/1.docx")
        try? FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not a Word file".utf8).write(to: brokenURL)
        state.convertMailDocument(brokenDoc, options: MailMergeOptions(readWithAI: false))
        let brokenEnded = await eventually(20) { !MailDocumentActivity.shared.isConverting(brokenDoc.id) && !state.mailBusy.contains(brokenDoc.id) }
        let brokenRow = try? await engine.db.mailItem(id: brokenDoc.id)
        let failed = state.toasts.filter { $0.id.hasPrefix("mail-convert") && $0.id.hasSuffix(brokenDoc.id) }
        c.check("docs action: a failed conversion posts the hint and leaves the row waiting with its reason",
                brokenStored != nil && brokenEnded && failed.count == 1 && failed[0].id == "mail-convert-failed-\(brokenDoc.id)"
                    && failed[0].kind == .warning && brokenRow?.status == .pending && !(brokenRow?.downloadError ?? "").isEmpty
                    && !MailDocumentActivity.shared.isConverting(brokenDoc.id),
                ["toasts": failed.map(\.id), "status": brokenRow?.status.rawValue, "error": brokenRow?.downloadError != nil])

        // 「打开」 for a row whose stored copy is gone: a warning, nothing opened.
        state.openMailDocument(slides)
        let refused = await eventually(3) { state.toasts.contains { $0.id == "mail-document-missing-\(slides.id)" } }
        c.check("docs action: opening a missing attachment warns and opens nothing", refused)

        defaults.removePersistentDomain(forName: suite)
        LangStore.shared.provider = savedProvider
        await close(engine)
    }
}
