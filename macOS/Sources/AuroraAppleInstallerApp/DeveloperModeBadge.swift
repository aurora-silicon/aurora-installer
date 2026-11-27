import AuroraInstallerUXCore
import SwiftUI

/// Shown at the top of the window while Developer mode is on, so nobody
/// installs from a developer channel without knowing it. Its button, or
/// Command-D again, turns Developer mode off.
struct DeveloperModeBadge: View {
  var onTurnOff: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "hammer.fill").imageScale(.small).accessibilityHidden(true)
      Text(PlainLanguage.developerModeBadge).font(InstallerTheme.badge)
      Button(PlainLanguage.developerModeLeave, action: onTurnOff)
        .buttonStyle(.borderless).controlSize(.small).font(InstallerTheme.badge)
        .accessibilityLabel(
          PlainLanguage.developerModeLeave + " " + PlainLanguage.developerModeBadge)
    }
    .foregroundStyle(InstallerTheme.caution)
    .padding(.horizontal, 12).padding(.vertical, 4)
    .background(Capsule().fill(InstallerTheme.caution.opacity(0.12)))
    .overlay(Capsule().strokeBorder(InstallerTheme.caution.opacity(0.35)))
    .help(PlainLanguage.developerModeBadgeHelp)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(PlainLanguage.developerModeBadge)
  }
}
