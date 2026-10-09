import AppKit
import SwiftUI

/// The 10-hue category palette (§8 卡片: "彩色分类 chip（10 色板，hue 自动分配）").
///
/// `color(hue:)` is the *ink*: text/dot colour chosen for ≥ 4.5:1 contrast on its own
/// tinted chip background in both appearances (dark ink in light mode, light ink in
/// dark mode). `fill(hue:)` is that tinted background.
enum ChipPalette {
    static let count = 10

    /// Ink colour for a category hue (any Int; wrapped into the palette).
    static func color(hue: Int) -> Color { inks[index(hue)] }

    /// Tinted chip background for a category hue.
    static func fill(hue: Int) -> Color { fills[index(hue)] }

    private static func index(_ hue: Int) -> Int { ((hue % count) + count) % count }

    //                               light ink, dark ink
    private static let pairs: [(UInt32, UInt32)] = [
        (0x1F5FBF, 0x86B6FF),   // 0 blue
        (0x1D7A3A, 0x72D491),   // 1 green
        (0x6B3FB8, 0xC2A6FF),   // 2 purple
        (0xA8500C, 0xFFB26B),   // 3 orange
        (0x0E7070, 0x62D5D5),   // 4 teal
        (0xB02E68, 0xFF92C2),   // 5 pink
        (0x3B45B5, 0x9FA8FF),   // 6 indigo
        (0x7A5230, 0xDDB38A),   // 7 brown
        (0x5A6612, 0xC8D65E),   // 8 olive
        (0xB3261E, 0xFF8D84),   // 9 red
    ]

    private static let inks: [Color] = pairs.map { dynamic(light: $0.0, dark: $0.1) }
    private static let fills: [Color] = pairs.map { dynamic(light: $0.0, dark: $0.1, lightAlpha: 0.12, darkAlpha: 0.20) }

    /// A light/dark aware colour. Built in a nonisolated context so AppKit may resolve it
    /// on any thread (the dynamic provider must not inherit MainActor isolation).
    nonisolated static func dynamic(light: UInt32, dark: UInt32,
                                    lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        let l = rgb(light, alpha: lightAlpha)
        let d = rgb(dark, alpha: darkAlpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }

    nonisolated private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}
