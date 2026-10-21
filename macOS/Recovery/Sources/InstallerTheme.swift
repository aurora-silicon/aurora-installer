import AppKit

/// Shared AppKit colors and type for the standalone Recovery application.
enum AuroraTheme {
  static let window = dynamic(light: 0xE1_E2E7, dark: 0x1A_1B26)
  static let card = dynamic(light: 0xFF_FFFF, dark: 0x24_283B)
  static let text = dynamic(light: 0x37_60BF, dark: 0xC0_CAF5)
  static let secondaryText = dynamic(light: 0x4A_5A9E, dark: 0x7A_A2F7)
  static let separator = dynamic(light: 0xC4_C8DA, dark: 0x41_4868)
  static let track = dynamic(light: 0xD0_D5E3, dark: 0x2F_334D)
  static let accent = dynamic(light: 0x2E_7DE9, dark: 0x7A_A2F7)
  static let accentText = dynamic(light: 0xFF_FFFF, dark: 0x1A_1B26)
  static let danger = dynamic(light: 0xF5_2A65, dark: 0xF7_768E)
  static let caution = dynamic(light: 0x8C_6C3E, dark: 0xE0_AF68)

  static let cardRadius: CGFloat = 8
  static let buttonRadius: CGFloat = 6
  static let buttonHeight: CGFloat = 34

  static let title = mono(22, .bold)
  static let heading = mono(15, .bold)
  static let body = mono(13)
  static let detail = mono(11)
  static let control = mono(12, .medium)
  static let button = mono(12, .bold)

  static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
  }

  static func darkCGColor(_ color: NSColor) -> CGColor {
    guard let appearance = NSAppearance(named: .darkAqua) else { return color.cgColor }
    var resolved = color.cgColor
    appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    return resolved
  }

  private static func dynamic(light: Int, dark: Int) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1)
    }
  }
}
