import AppKit
import SwiftUI
import PaperDeckCore

/// The reader window's content (LN §8 minimal reader): thumbnails | the page view with its overlays
/// (find bar, the selection / region toolbars, the box being drawn, a passing note), and the bridged
/// toolbar (thumbnails · page field · zoom · region · find · Ask · Open in Preview). Owned by Slice C.
struct ReaderView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        content
            .frame(minWidth: 480, minHeight: 420)
            .navigationTitle(model.title)
            .navigationSubtitle(subtitle)
            .toolbar { ReaderToolbar(model: model) }
            .background(ReaderShortcuts(model: model))
    }

    private var subtitle: String {
        model.phase == .reading ? L.Reader.pageOf(model.page, model.pageCount, printed: model.printedLabel) : ""
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView(L.Reader.loading)
                if model.loadIsSlow {
                    Text(L.Reader.loadingSlowHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button(L.Reader.cancelOpening) { model.cancelLoading() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .timedOut:
            ContentUnavailableView {
                Label(L.Reader.timedOut, systemImage: "icloud.and.arrow.down")
            } description: {
                Text(L.Reader.timedOutHint)
            } actions: {
                Button(L.Reader.tryAgain) { model.retryLoad() }
                Button(L.Reader.openInPreview) { ReaderRouter.openInPreview(model.url) }
            }
        case .missing:
            unavailable(L.pdfMissing, "doc.questionmark", L.Reader.missingHint, preview: false)
        case .unreadable:
            unavailable(L.Reader.unreadable, "exclamationmark.triangle", L.Reader.unreadableHint, preview: true)
        case .locked:
            unavailable(L.Reader.locked, "lock.doc", L.Reader.lockedHint, preview: true)
        case .reading:
            HStack(spacing: 0) {
                if model.showThumbnails {
                    ReaderThumbnailsRepresentable(model: model)
                        .frame(width: 132)
                        .background(.background.secondary)
                    Divider()
                }
                pageArea
            }
        }
    }

    private func unavailable(_ title: String, _ symbol: String, _ hint: String, preview: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(hint)
        } actions: {
            if preview { Button(L.Reader.openInPreview) { ReaderRouter.openInPreview(model.url) } }
        }
    }

    private var pageArea: some View {
        ReaderPDFRepresentable(model: model)
            .overlay { ReaderOverlays(model: model) }
            .overlay(alignment: .top) {
                if model.findVisible {
                    ReaderFindBar(model: model)
                        .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Text(Self.text(notice))
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.notice)
    }

    static func text(_ notice: ReaderModel.Notice) -> String {
        switch notice {
        case .quoteNotFound(let page): L.Reader.quoteNotFound(L.Reader.pageChip(page, printed: nil))
        case .quotePartial: L.Reader.quotePartial
        case .copied: L.Reader.copied
        }
    }
}

/// The box being drawn, the finished box with its toolbar, and the selection's toolbar — positioned
/// from page rects the model keeps in view coordinates (origin top-left). Only the toolbars take clicks.
struct ReaderOverlays: View {
    let model: ReaderModel
    @State private var barSize = CGSize(width: 260, height: 30)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let band = model.band {
                    box(band, dashed: true)
                }
                if let region = model.region {
                    box(region.viewRect, dashed: false)
                    toolbar(region, in: geo.size)
                } else if model.band == nil, let selection = model.selection {
                    toolbar(selection, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func box(_ r: CGRect, dashed: Bool) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(dashed ? 0.06 : 0.1))
            .overlay(Rectangle().strokeBorder(Color.accentColor,
                                              style: StrokeStyle(lineWidth: dashed ? 1.5 : 2, dash: dashed ? [5, 3] : [])))
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func toolbar(_ target: ReaderModel.Target, in size: CGSize) -> some View {
        if let center = ReaderOverlayPlacement.toolbarCenter(target: target.viewRect, toolbar: barSize, viewport: size) {
            ReaderSelectionToolbar(model: model, target: target)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(center)
        }
    }
}

/// ⌘F's find bar: the query (debounced; Return runs it / goes to the next match), "3 of 12", ‹ ›, Done.
struct ReaderFindBar: View {
    @Bindable var model: ReaderModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L.Reader.findPlaceholder, text: $model.findQuery)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .focused($focused)
                .onSubmit {
                    // Still searching (off the main actor): Return waits for the first match.
                    if model.findCursor.count > 0 { model.findNext() } else if model.findProgress == nil { model.runFind() }
                }
                .onExitCommand { model.closeFind() }
            Text(position)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                .help(L.Reader.findPrevious)
                .accessibilityLabel(L.Reader.findPrevious)
                .disabled(model.findCursor.count == 0)
            Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                .help(L.Reader.findNext)
                .accessibilityLabel(L.Reader.findNext)
                .disabled(model.findCursor.count == 0)
            Button(L.Reader.done) { model.closeFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
    }

    private var position: String {
        guard !model.findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        if let progress = model.findProgress {
            let searching = L.Reader.findSearching(Int((progress * 100).rounded()))
            guard let i = model.findCursor.position else {
                return model.findCursor.count > 0 ? L.Reader.findFound(model.findCursor.count) + " · " + searching : searching
            }
            return L.Reader.findPosition(i, model.findCursor.count) + " · " + searching
        }
        guard let i = model.findCursor.position else { return L.Reader.findNone }
        let base = L.Reader.findPosition(i, model.findCursor.count)
        return model.findCapped ? base + " · " + L.Reader.findCapped(ReaderModel.findLimit) : base
    }
}

/// Thumbnails · page field ("3 of 14 · printed 1203") · zoom · region · find · Ask · Open in Preview.
struct ReaderToolbar: ToolbarContent {
    @Bindable var model: ReaderModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showThumbnails.toggle() } label: {
                Label(model.showThumbnails ? L.Reader.hideThumbnails : L.Reader.showThumbnails, systemImage: "sidebar.leading")
            }
            .help(model.showThumbnails ? L.Reader.hideThumbnails : L.Reader.showThumbnails)
            .disabled(model.phase != .reading)
        }
        ToolbarItem(placement: .navigation) {
            if model.phase == .reading { ReaderPageField(model: model) }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.zoomOut() } label: { Label(L.Reader.zoomOut, systemImage: "minus.magnifyingglass") }
                .help(L.Reader.zoomOut)
                .disabled(model.phase != .reading)
            Button { model.zoomIn() } label: { Label(L.Reader.zoomIn, systemImage: "plus.magnifyingglass") }
                .help(L.Reader.zoomIn)
                .disabled(model.phase != .reading)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.regionMode) { Label(L.Reader.region, systemImage: "viewfinder") }
                .help(L.Reader.regionHelp)
                .disabled(model.phase != .reading)
            Button { model.showFind() } label: { Label(L.Reader.find, systemImage: "magnifyingglass") }
                .help(L.Reader.findHelp)
                .disabled(model.phase != .reading)
            if AssistRollout.ask {
                Button { AskRouter.ask(paperIDs: [model.paperID], prefill: nil) } label: {
                    Label(L.Reader.ask, systemImage: "bubble.left.and.text.bubble.right")
                }
                .help(L.Reader.askHelp)
                .disabled(model.phase != .reading)
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { ReaderRouter.openInPreview(model.url) } label: {
                Label(L.Reader.openInPreview, systemImage: "arrow.up.forward.app")
            }
            .help(L.Reader.openInPreviewHelp)
            .disabled(model.phase == .missing)
        }
    }
}

/// "[ 3 ] of 14" (the printed label is in the window subtitle): type a physical number or a printed
/// label, Return goes there.
struct ReaderPageField: View {
    let model: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            TextField(L.Reader.pageField, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 52)
                .focused($focused)
                .onSubmit {
                    if !model.go(toField: text) { NSSound.beep() }
                    text = String(model.page)
                    focused = false
                }
                .help(L.Reader.pageFieldHelp)
                .accessibilityLabel(L.Reader.pageField)
            Text(L.Reader.ofCount(model.pageCount))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .onAppear { text = String(model.page) }
        .onChange(of: model.page) { if !focused { text = String(model.page) } }
    }
}

/// Window shortcuts without an always-visible control (zero-size, invisible buttons; never ⌘A):
/// ⌘F find, ⌘G / ⇧⌘G next / previous match, ⌘= / ⌘- zoom, ⌘0 actual size, ⌘9 fit width.
struct ReaderShortcuts: View {
    let model: ReaderModel

    var body: some View {
        ZStack {
            Button("") { model.showFind() }.keyboardShortcut("f", modifiers: .command)
            Button("") { model.findNext() }.keyboardShortcut("g", modifiers: .command)
            Button("") { model.findPrevious() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") { model.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { model.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { model.actualSize() }.keyboardShortcut("0", modifiers: .command)
            Button("") { model.fitWidth() }.keyboardShortcut("9", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(model.phase != .reading)
    }
}
