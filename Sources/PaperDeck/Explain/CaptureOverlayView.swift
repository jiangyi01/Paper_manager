import SwiftUI
import PaperDeckCore

/// What the overlay's buttons do.
struct CaptureOverlayActions {
    var dismiss: () -> Void = {}
    var setMode: (AssistSettings.OverlayMode) -> Void = { _ in }
    /// The offer chip's button (the same as Return).
    var explainOffer: () -> Void = {}
    var enableCapture: () -> Void = {}
    var openSystemSettings: () -> Void = {}
}

/// One display's overlay content (dive-capture §2 "hud"): a light dim that keeps clicks from falling
/// through (a click outside the cards cancels), the HUD pill at the top of the display under the
/// mouse — just under its menu bar / notch, stepping to the bottom edge while the pointer is near it
/// and hidden while a box is drawn (CUX-14) — the clipboard offer, a "nothing legible" notice
/// (CUX-8), and — while Screen Recording is off — the card with the zero-permission ways. The
/// capture lane's frame / lens layer (A3) sits between the dim and the HUD.
struct CaptureOverlayView: View {
    let model: CaptureOverlayModel
    /// The display under the mouse shows the HUD and cards.
    let active: Bool
    let layer: AnyView?
    var actions = CaptureOverlayActions()
    var style: PanelChromeStyle = .glass

    var body: some View {
        ZStack {
            Color.black.opacity(model.captureAllowed && model.hasCaptureLayer ? 0.18 : 0.06)
                .contentShape(Rectangle())
                .onTapGesture { actions.dismiss() }
            if let layer { layer }
            if active {
                VStack(spacing: 14) {
                    if model.hudEdge == .top { hudSlot }
                    Spacer()
                    if !model.captureAllowed || !model.hasCaptureLayer || model.freezeFailed { captureCard }
                    if let notice = model.notice { noticeChip(notice) }
                    Spacer()
                    offerChip
                        .opacity(model.dragging ? 0 : 1)
                        .allowsHitTesting(!model.dragging)
                    if model.hudEdge == .bottom { hudSlot }
                }
                .padding(.top, model.hudTopInset + CaptureHUD.margin)
                .padding(.bottom, CaptureHUD.bottomInset)
                .animation(.easeOut(duration: 0.15), value: model.hudEdge)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: HUD

    /// The pill where it is; while a box is drawn it is hidden and lets the mouse through.
    private var hudSlot: some View {
        let shown = CaptureHUD.isShown(dragging: model.dragging)
        return hud
            .frame(height: CaptureHUD.height)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Picker(selection: Binding(get: { model.mode }, set: { actions.setMode($0) })) {
                Label(L.Explain.modeFrame, systemImage: "rectangle.dashed").tag(AssistSettings.OverlayMode.frame)
                Label(L.Explain.modeLens, systemImage: "magnifyingglass").tag(AssistSettings.OverlayMode.lens)
            } label: {
                Text(L.Explain.modeFrame)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .disabled(!model.captureAllowed || !model.hasCaptureLayer || model.freezeFailed)
            if model.captureAllowed, model.hasCaptureLayer, !model.freezeFailed {
                Text(model.mode == .frame ? L.Explain.hudHint : L.Explain.hudLensHint)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.8))       // readable over a white page and a dark app
            }
            if let lang = model.language {
                Text(verbatim: lang == .zh ? "中" : "EN")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Button(action: actions.dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L.Explain.close)
            .accessibilityLabel(L.Explain.close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(OverlayChrome(style: style, shape: Capsule(), solid: true))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// "Nothing legible here …" / "The capture came back blank …": the overlay stays, nothing was sent.
    private func noticeChip(_ notice: CaptureOverlayModel.Notice) -> some View {
        Label(notice.text, systemImage: notice.symbol)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(OverlayChrome(style: .material, shape: Capsule(), solid: true))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .accessibilityAddTraits(.isStaticText)
    }

    // MARK: Cards

    /// Screen Recording off, or this capture failed: the ways that need nothing.
    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.captureAllowed ? L.Explain.captureFailedTitle : L.Explain.captureOffTitle,
                  systemImage: model.captureAllowed ? "exclamationmark.triangle" : "lock.shield")
                .font(.headline)
            Text(model.captureAllowed ? L.Explain.captureFailedBody(model.hotkey) : L.Explain.captureOffBody(model.hotkey))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.captureAllowed {
                HStack(spacing: 8) {
                    Spacer()
                    Button(L.Explain.openSystemSettings, action: actions.openSystemSettings)
                    Button(L.Explain.enableCapture, action: actions.enableCapture).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .modifier(OverlayChrome(style: .material, shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
    }

    @ViewBuilder
    private var offerChip: some View {
        if let offer = model.offer {
            Button(action: actions.explainOffer) {
                HStack(spacing: 8) {
                    Image(systemName: offer.content == .text ? "doc.on.clipboard" : "photo.on.rectangle")
                    Text(offer.content == .text ? L.Explain.clipboardOffer : L.Explain.clipboardImageOffer)
                    Text(verbatim: "⏎").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .modifier(OverlayChrome(style: style, shape: Capsule(), solid: true))
        } else {
            Text(L.Explain.clipboardNone)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(OverlayChrome(style: .material, shape: Capsule(), solid: true))
        }
    }
}

/// Glass on screen, material in renders (glass doesn't draw offscreen). `solid`: tinted with the
/// window background so text stays readable over any page (a white PDF under a dark-mode HUD).
struct OverlayChrome<S: Shape>: ViewModifier {
    let style: PanelChromeStyle
    let shape: S
    var solid = false

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            if solid {
                content.glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.85)), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        case .material:
            content
                .background(solid ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
                // Solid: a nearly opaque backing, so the page under the pill never shows through its text.
                .background(Color(nsColor: .windowBackgroundColor).opacity(solid ? 0.9 : 0), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(solid ? 0.16 : 0.10), lineWidth: 0.5))
        }
    }
}
