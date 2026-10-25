import SwiftUI
import UIKit

/// Flat, near-monochrome palette with one muted accent. Every color adapts to light/dark mode.
enum Theme {
    static let background   = dynamic(light: 0xF4F4F2, dark: 0x0C0C0C)
    static let display      = dynamic(light: 0xFFFFFF, dark: 0x161616)
    static let hairline     = dynamic(light: 0xDCDCD8, dark: 0x2C2C2C)
    static let primary      = dynamic(light: 0x141414, dark: 0xECECEC)
    static let secondary    = dynamic(light: 0x8A8A86, dark: 0x8A8A8A)
    static let track        = dynamic(light: 0xE6E6E3, dark: 0x2A2A2A)
    static let wheel        = dynamic(light: 0xE8E8E5, dark: 0x1C1C1C)
    static let wheelPressed = dynamic(light: 0xDDDDDA, dark: 0x252525)
    /// The one accent: a quiet slate blue, used for progress fills and the playing glyph.
    static let accent       = dynamic(light: 0x4C6FA8, dark: 0x86A6D8)

    /// Selected menu row: inverted, like a monochrome LCD.
    static let selectionFill = primary
    static let selectionText = display

    static let rowFont = Font.system(size: 17, weight: .regular)
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let monoFont = Font.system(size: 12, weight: .regular, design: .monospaced)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
