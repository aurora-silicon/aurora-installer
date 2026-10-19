import AppKit
import SwiftUI

/// Follow macOS appearance, accessibility contrast and the user's accent.
enum RecoveryAppearance {
  static let window = Color(nsColor: .windowBackgroundColor)
  static let text = Color.primary
  static let secondaryText = Color.secondary
  static let accent = Color.accentColor
  static let danger = Color(nsColor: .systemRed)
  static let title = Font.system(size: 26, weight: .bold)
  static let detail = Font.system(size: 12)

  static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}
