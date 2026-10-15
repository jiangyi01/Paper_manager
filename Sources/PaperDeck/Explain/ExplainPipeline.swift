import AppKit
import ImageIO
import PaperDeckCore

/// The panels' live services: Core's `ExplainEngineServices` (privacy, the lane, the store) with the
/// capture lane's local pieces plugged in — Vision OCR, the region classifier, the paper locator and
/// context builder, the prompt builder (Core/Capture). This file is the one place that calls the
/// capture lane's contracts, so a change there is a change here only. Nothing here mints a ticket or
/// starts a turn. Owned by the Explain UI lane (A2).
final class LiveExplainServices {
    /// The OCR languages (Vision): English and Simplified Chinese.
    static let ocrLanguages = ["en-US", "zh-Hans"]

    /// The prompt context of each prepared capture (the prompt builder's own type), and which
    /// panel's thread uses it (dropped when the panel closes).
    private var contexts: [UUID: ExplainContext] = [:]
    private var preparedOfThread: [String: UUID] = [:]
    private let engine: Engine

    private init(engine: Engine) { self.engine = engine }

    /// The services every panel of the app uses.
    static func make(engine: Engine) -> ExplainEngineServices {
        let adapter = LiveExplainServices(engine: engine)
        let services = ExplainEngineServices(
            engine: engine,
            prepare: { capture, anchor in await adapter.prepare(capture, anchor: anchor) },
            build: { spec in adapter.request(spec) })
        services.onHistoryChange = { NotificationCenter.default.post(name: .explainHistoryChanged, object: nil) }
        services.onClose = { key in adapter.forget(threadKey: key) }
        return services
    }

    /// OCR (an image without text), what the region holds, which paper, the prompt context. OCR and
    /// the click's paragraph read the full-resolution crop when the overlay kept one
    /// (`capture.ocrImage`, CUX-7) — for a click the band first, then once the larger area around it
    /// when the paragraph runs past the band (CUX-8); only the downscaled `image` — or the paragraph
    /// cut from the full-resolution crop, then downscaled — may be sent. A capture over PaperDeck's own
    /// reader is that reader's paper (F2); the windows under what is sent go with it for the privacy
    /// check (F1).
    func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared {
        var selection = capture.text.flatMap { ClipboardOffer.normalize($0) } ?? anchor?.text
        let exact = selection != nil
        var content: ExplainPrepared.Content = .text
        var image = capture.image
        // The text the paper is located by and its context centred on (a clicked term's paragraph).
        var around: String?
        // The part of the capture actually sent, as a fraction of it (nil: all of it).
        var sentUnit: CGRect?
        if let captured = capture.image, let cg = capture.ocrImage ?? ExplainImages.cgImage(captured) {
            if selection == nil {
                // A screen region, a screenshot, a dropped image: Vision reads it locally.
                let size = CGSize(width: cg.width, height: cg.height)
                if let focus = capture.focus {
                    // A click: only the paragraph (or ⇧ the term) under it — read in the band, and once more
                    // in the area around it when it runs past the band's edge; nothing readable under it (or
                    // OCR failed) → the figure / small band the overlay found around the click
                    // (`ExplainFocusResolver.unresolved`), never the whole band.
                    let hit = await ExplainFocusResolver.read(focus, imageSize: size) { rect in await Self.recognize(cg, in: rect) }
                    selection = hit.selection.flatMap { ClipboardOffer.normalize($0) }
                    around = hit.paragraph.flatMap { ClipboardOffer.normalize($0) }
                    if let crop = hit.crop, let part = cg.cropping(to: crop), let encoded = ExplainImageEncoder.encode(part) {
                        image = encoded
                        sentUnit = ExplainPreparation.unit(crop, of: size)
                    }
                    if focus.term, selection != nil {
                        content = .text
                    } else {
                        content = hit.block.map { Self.content(RegionClassifier.classify($0, imageSize: hit.crop?.size ?? size)) }
                            ?? .visual
                    }
                } else {
                    let ocr = try? await OCREngine.recognize(cg, languages: Self.ocrLanguages, customWords: [])
                    selection = ocr.flatMap { ClipboardOffer.normalize($0.text) }
                    content = ocr.map { Self.content(RegionClassifier.classify($0, imageSize: size)) } ?? .visual
                }
            } else {
                content = .mixed                  // a reader box: the exact text plus its drawing
            }
        }
        // What the locator matches and the context centres on; a correction of the match is remembered
        // under it too (`ExplainPrepared.locatedText`), so explaining again finds that correction.
        let located = around ?? selection
        let match: PaperMatch?
        if let known = ExplainPreparation.knownMatch(anchor: anchor, surroundings: capture.surroundings) {
            match = known                                  // the reader's toolbar, or a capture over PaperDeck's reader
        } else {
            match = await PaperLocator.locate(windowTitle: capture.windowTitle, ocrText: located, engine: engine)
        }
        let prepared = ExplainPrepared(selection: selection, image: image, content: content, match: match,
                                       selectionIsExact: exact, locatedText: located,
                                       surroundings: ExplainPreparation.sentSurroundings(capture.surroundings, sentUnit: sentUnit))
        contexts[prepared.id] = await PaperContextBuilder.context(for: match, around: located, engine: engine)
        return prepared
    }

    /// Vision's reading of `rect` (pixels) of `image`, in that part's own pixels; nil when it failed.
    static func recognize(_ image: CGImage, in rect: CGRect) async -> OCRResult? {
        let whole = rect == CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let part = whole ? image : image.cropping(to: rect) else { return nil }
        return try? await OCREngine.recognize(part, languages: ocrLanguages, customWords: [])
    }

    static func content(_ kind: RegionKind) -> ExplainPrepared.Content {
        switch kind {
        case .text: return .text
        case .mixed: return .mixed
        case .visual: return .visual
        }
    }

    /// The panel's turn kind as the prompt builder names it.
    static func promptKind(_ k: ExplainTurnKind) -> ExplainKind {
        switch k {
        case .explain: return .explain
        case .simpler: return .simpler
        case .technical: return .technical
        case .defineTerms: return .terms
        case .figure: return .figure
        case .translate: return .translate
        case .ask(let q): return .ask(q)
        }
    }

    /// The prompt builder's request for one turn: the panel's session, depth and history go in its
    /// options (Core's `finish` then pins the session, model, image and limits again).
    func request(_ spec: ExplainTurnSpec) -> AssistRequest {
        let p = spec.prepared
        preparedOfThread[spec.threadKey] = p.id
        let options = ExplainPrompt.Options(settings: engine.ctx.loadSettings().assist, depth: spec.depth,
                                            reader: engine.loadAssistReader(), session: .reuse(threadKey: spec.threadKey),
                                            history: spec.history, selectionIsExact: p.selectionIsExact)
        return ExplainPrompt.request(kind: Self.promptKind(spec.kind), language: spec.language == .zh ? .zh : .en,
                                     level: spec.level, context: contexts[p.id] ?? ExplainContext(), selection: p.selection,
                                     image: spec.sendImage ? p.image.flatMap(ExplainImages.cgImage) : nil, options: options)
    }

    func forget(threadKey: String) {
        if let id = preparedOfThread.removeValue(forKey: threadKey) { contexts[id] = nil }
    }

    /// The real screen capturer (the capture lane's). It never asks for Screen Recording; with it
    /// granted the overlay freezes every display once when it opens (kept in memory, dropped when
    /// the overlay closes) and crops the user's box or click from that still — nothing leaves the
    /// Mac until a turn is sent.
    static func liveCapturer() -> any ScreenCapturing { ScreenCapturer() }
}

/// Image plumbing of the App side.
enum ExplainImages {
    /// A turn image decoded for OCR.
    static func cgImage(_ image: AssistImage) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(image.data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// A small preview of a capture for the panel's quote line.
    static func thumbnail(_ image: AssistImage) -> NSImage? { NSImage(data: image.data) }
}
