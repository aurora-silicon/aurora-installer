import AppKit
import SwiftUI

// Native macOS appearance, shared with the Aurora Recovery interface.
enum OmarchyTheme {
  static let window = Color(nsColor: .windowBackgroundColor)
  static let card = Color(nsColor: .controlBackgroundColor)
  static let text = Color.primary
  static let secondaryText = Color.secondary
  static let separator = Color(nsColor: .separatorColor)
  static let track = Color.primary.opacity(0.08)
  static let accent = Color(nsColor: .labelColor)
  static let accentText = Color(nsColor: .windowBackgroundColor)
  static let success = Color.green
  static let danger = Color.red
  static let caution = Color.orange
  static let handle = Color.secondary
  static let buttonHover = Color.primary.opacity(0.9)
  static let buttonPressed = Color.primary.opacity(0.75)
  static let buttonHoverText = Color.primary
  static let buttonPressedSurface = Color.primary.opacity(0.08)
  static let cardRadius: CGFloat = 18
  static let buttonRadius: CGFloat = 8
  static let buttonHeight: CGFloat = 36
  static let buttonTracking: CGFloat = 0
  static let helpLineSpacing: CGFloat = 3
  static let title = Font.system(size: 28, weight: .semibold)
  static let sheetTitle = Font.system(size: 20, weight: .semibold)
  static let heading = Font.system(size: 16, weight: .semibold)
  static let eyebrow = Font.system(size: 12, weight: .medium)
  static let body = Font.system(size: 14)
  static let detail = Font.system(size: 12)
  static let control = Font.system(size: 13)
  static let button = Font.system(size: 13)
  static let badge = Font.system(size: 11, weight: .medium)
  static let technical = Font.system(size: 11, design: .monospaced)
  static let numeral = Font.system(size: 13, weight: .medium).monospacedDigit()
  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }
}

extension View {
  func omarchyHelpText() -> some View {
    font(OmarchyTheme.detail).foregroundStyle(.secondary)
      .lineSpacing(OmarchyTheme.helpLineSpacing).fixedSize(horizontal: false, vertical: true)
  }
  func omarchyTypography() -> some View { font(OmarchyTheme.body) }
}
