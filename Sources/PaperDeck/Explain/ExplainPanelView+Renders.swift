import AppKit
import SwiftUI
import PaperDeckCore

/// `--explain-render`'s states of the capture / panel fixes (fix-capture-ux), drawn over the render
/// tool's frozen fixture screen (in memory, never a screenshot) and its scratch library: what an
/// ⌥-click and a click send (`CaptureClickPlan` on the fixture's pixels) with the panel's "This is
/// what will be sent" thumbnail, the match line ("Matched: … · Change… · Not this paper", a chosen
/// paper, none), the HUD stepped to the bottom edge, hidden while a box is drawn, and the "nothing
/// legible" notice. Fixtures over no-op services: nothing is prepared, sent or stored.
enum ExplainUXRenders {
    static func draw(state: AppState, paperID: String, excerpt: String, appearance: NSAppearance?,
                     png: (String) -> URL) async throws {
        let screen = NSSize(width: 1280, height: 800)
        guard let still = ExplainRenders.Fixture.screen(size: screen) else { return }
        let display = FrozenDisplay(id: 1, frame: CGRect(origin: .zero, size: screen), scale: 2, image: still)
        let frozen = FrozenScreens(displays: [display])
        let crop: (CGRect) -> CGImage? = { CaptureGeometry.crop(frozen, CaptureRegion(displayID: 1, rect: $0)) }
        let zh = L.lang == .zh

        // The overlay: what an ⌥-click on the chart sends (its own bounds), drawn as the box.
        let onBar = CGPoint(x: 400, y: 560)
        let figurePlan = CaptureClickPlan.plan(click: onBar, displaySize: screen, window: nil, term: false, figure: true, crop: crop)
        func overlay(_ name: String, box: CGRect? = nil, cursor: CGPoint? = nil, option: Bool = false, dragging: Bool = false,
                     notice: CaptureOverlayModel.Notice? = nil) async throws {
            let m = CaptureOverlayModel()
            m.captureAllowed = true
            m.hasCaptureLayer = true
            m.frozenReady = true
            m.mode = .frame
            m.optionHeld = option
            m.dragging = dragging
            m.notice = notice
            m.hotkey = HotKeySpec.display(.defaultExplain)
            m.offer = ClipboardOffer(content: .text, changeCount: 9)
            m.hudEdge = CaptureHUD.edge(current: .top, cursor: cursor, displaySize: screen, topInset: 0)
            let layer = CaptureLayerModel(displayID: 1, size: screen, still: display)
            if let box {
                layer.dragStart = box.origin
                layer.dragEnd = CGPoint(x: box.maxX, y: box.maxY)
            }
            layer.cursor = cursor ?? box.map { CGPoint(x: $0.maxX, y: $0.maxY) }
            let view = CaptureOverlayView(model: m, active: true, layer: AnyView(CaptureLayerView(layer: layer, overlay: m)),
                                          style: .material)
            try await PreviewRenderer.captureView(view.frame(width: screen.width, height: screen.height), size: screen,
                                                  appearance: appearance, png("overlay-" + name))
        }
        if case .figure(let rect)? = figurePlan {
            try await overlay("ux-option-click-figure", box: rect, cursor: onBar, option: true)
        }
        // The pointer at the top (to box the title): the HUD has stepped to the bottom edge.
        try await overlay("ux-hud-bottom", cursor: CGPoint(x: 640, y: 40))
        // A box being drawn: the HUD and the offer are hidden.
        try await overlay("ux-dragging", box: CGRect(x: 262, y: 120, width: 616, height: 90), dragging: true)
        // A click on nothing legible: the notice, nothing sent.
        try await overlay("ux-nothing-legible", cursor: CGPoint(x: 120, y: 700), notice: .nothingLegible)

        // The panel: what a click sends, and the match line.
        let services = PlaceholderExplainServices()            // never called: the states are fixtures
        let now = Date()
        let meta = AssistMeta(provider: "claude", model: "haiku", turnIndex: 0, ttftMs: 1_900, totalMs: 5_400)
        func panel(_ name: String, capture: ExplainCapture, prepared: ExplainPrepared, kind: ExplainTurnKind = .explain,
                   answer: String) async throws {
            let s = ExplainPanelState(capture: capture, services: services, language: zh ? .zh : .en, depth: .quick)
            var t = ExplainTurn(index: 0, kind: kind, language: zh ? .zh : .en, depth: .quick,
                                sentImage: ExplainPanelState.sendsImage(kind, prepared: prepared, override: nil), text: answer,
                                startedAt: now.addingTimeInterval(-6))
            t.meta = meta
            t.recordID = "r0"
            s.applyRenderFixture(phase: .done, turns: [t], prepared: prepared)
            let size = NSSize(width: 420, height: 460)
            let view = ExplainPanelView(state: s, app: state, focus: ExplainPanelFocus(), style: .material, previewNow: now)
                .frame(width: size.width, height: size.height)
            try await PreviewRenderer.captureView(view, size: size, appearance: appearance, png("panel-" + name))
        }
        let figureAnswer = zh ? "**图 3**：柱子是截肢后各天恢复的鳍长百分比，前 4 天增长最快。"
                              : "**Figure 3**: each bar is the regrown fin length (%) on a day after amputation; growth is fastest early."
        let clickPlan = CaptureClickPlan.plan(click: onBar, displaySize: screen, window: nil, term: false, figure: false, crop: crop)
        if case .paragraph(let band, let focus)? = clickPlan, let bandImage = crop(band),
           let encodedBand = ExplainImageEncoder.encode(bandImage) {
            let px = CGSize(width: bandImage.width, height: bandImage.height)
            // Nothing readable under the click: only the figure the overlay found goes.
            let hit = ExplainFocusResolver.resolve(.empty, imageSize: px, focus: focus)
            if let r = hit.crop, let part = bandImage.cropping(to: r), let figure = ExplainImageEncoder.encode(part) {
                try await panel("ux-click-figure", capture: ExplainCapture(source: .region, image: encodedBand, focus: focus),
                                prepared: ExplainPrepared(selection: nil, image: figure, content: .visual, match: nil, selectionIsExact: false),
                                kind: .explain, answer: figureAnswer)
            }
        }
        // A click on a paragraph: its crop is shown; only its text goes.
        let paragraph = CGRect(x: 262, y: 124, width: 660, height: 76)        // the excerpt's paragraph on the fixture page
        if let part = crop(paragraph), let image = ExplainImageEncoder.encode(part) {
            let text = zh ? "作者用带温度的 softmax 约束注意力权重，让芽基信号在早期占主导。"
                          : "The authors constrain the attention weights with a temperature-scaled softmax."
            try await panel("ux-click-text", capture: ExplainCapture(source: .region, image: image),
                            prepared: ExplainPrepared(selection: excerpt, image: image, content: .text,
                                                      match: PaperMatch(paperID: paperID, page: 3, confidence: 0.83, via: .text),
                                                      selectionIsExact: false),
                            answer: text)
        }
        let simple = zh ? "简单说：模型更专注于芽基信号。" : "In short: the model focuses on the blastema signal."
        try await panel("ux-matched", capture: ExplainCapture(source: .clipboard, text: excerpt),
                        prepared: ExplainPrepared(selection: excerpt, image: nil, content: .text,
                                                  match: PaperMatch(paperID: paperID, page: 3, confidence: 0.9, via: .windowTitle)),
                        answer: simple)
        try await panel("ux-chosen", capture: ExplainCapture(source: .clipboard, text: excerpt),
                        prepared: ExplainPrepared(selection: excerpt, image: nil, content: .text,
                                                  match: PaperMatch(paperID: paperID, page: 3, confidence: 1, via: .user)),
                        answer: simple)
        try await panel("ux-unmatched", capture: ExplainCapture(source: .clipboard, text: excerpt),
                        prepared: ExplainPrepared(selection: excerpt, image: nil, content: .text, match: nil), answer: simple)
    }
}
