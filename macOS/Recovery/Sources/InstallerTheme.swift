import AppKit

/// Native macOS appearance shared with the Aurora desktop installer.
enum AuroraTheme {
  static let window = NSColor.windowBackgroundColor
  static let card = NSColor.controlBackgroundColor
  static let text = NSColor.labelColor
  static let secondaryText = NSColor.secondaryLabelColor
  static let separator = NSColor.separatorColor
  static let track = NSColor.quaternaryLabelColor
  static let accent = NSColor.controlAccentColor
  static let accentText = NSColor.white
  static let danger = NSColor.systemRed
  static let caution = NSColor.systemOrange

  static let cardRadius: CGFloat = 12
  static let buttonRadius: CGFloat = 6
  static let buttonHeight: CGFloat = 32

  static let title = font(24, .semibold)
  static let heading = font(17, .semibold)
  static let body = font(14)
  static let detail = font(12)
  static let control = font(13, .medium)
  static let button = font(13, .semibold)

  static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  static func darkCGColor(_ color: NSColor) -> CGColor {
    guard let appearance = NSAppearance(named: .darkAqua) else { return color.cgColor }
    var resolved = color.cgColor
    appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    return resolved
  }

}
