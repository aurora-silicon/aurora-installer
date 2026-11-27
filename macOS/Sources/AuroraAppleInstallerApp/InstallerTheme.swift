import AppKit
import SwiftUI

// Native macOS appearance, shared with the Aurora Recovery interface.
enum InstallerTheme {
  // Colour: system semantic colours plus the system accent. Colour is never
  // the only signal; warnings and errors also carry an icon or a word.
  static let window = Color(nsColor: .windowBackgroundColor)
  static let card = Color(nsColor: .controlBackgroundColor)
  static let text = Color.primary
  static let secondaryText = Color.secondary
  static let separator = Color(nsColor: .separatorColor)
  static let track = Color.primary.opacity(0.08)
  static let accent = Color.accentColor
  static let accentText = Color.white
  static let success = Color.green
  static let danger = Color.red
  /// For icons and tinted backgrounds only, never for running text.
  static let caution = Color.orange

  // Shape and size.
  static let cardRadius: CGFloat = 12
  static let controlRadius: CGFloat = 8
  static let chipRadius: CGFloat = 4
  static let buttonHeight: CGFloat = 36
  static let helpLineSpacing: CGFloat = 2

  // Type: SwiftUI text styles only, so sizes stay consistent and native.
  /// One per page.
  static let title = Font.title.weight(.semibold)
  /// Every sheet title.
  static let sheetTitle = Font.title3.weight(.semibold)
  /// Capacity numbers.
  static let display = Font.system(.largeTitle, design: .rounded).weight(.medium)
  static let heading = Font.headline
  /// Card and row names.
  static let label = Font.body.weight(.medium)
  /// "Distribution", "Disk" and other section heads.
  static let sectionLabel = Font.subheadline.weight(.semibold)
  static let body = Font.body
  static let detail = Font.callout
  static let caption = Font.subheadline
  static let control = Font.body
  static let badge = Font.subheadline.weight(.medium)
  static let technical = Font.system(.subheadline, design: .monospaced)
  static let numeral = Font.body.weight(.medium).monospacedDigit()
}

/// The spacing scale: a 4-pt base on an 8-pt rhythm. Use these, not literals.
enum Space {
  /// Label and value inside one line group.
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  /// Related controls, icon to text.
  static let s: CGFloat = 8
  /// Button gap, row padding.
  static let m: CGFloat = 12
  /// Between blocks on a page, card padding.
  static let l: CGFloat = 16
  /// Sheet padding, section gap, title to content.
  static let xl: CGFloat = 24
  /// Page top and bottom.
  static let xxl: CGFloat = 32
}

extension View {
  func auroraHelpText() -> some View {
    font(InstallerTheme.detail).foregroundStyle(.secondary)
      .lineSpacing(InstallerTheme.helpLineSpacing).fixedSize(horizontal: false, vertical: true)
  }
  func auroraTypography() -> some View { font(InstallerTheme.body) }
}
