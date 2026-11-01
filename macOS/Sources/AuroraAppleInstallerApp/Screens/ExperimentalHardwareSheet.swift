import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

/// The opt-in for a Mac the release does not support. It names the risk in
/// plain words, lets the owner pick how far to go, and needs a typed phrase:
/// the primary button stays off until the phrase matches, and Return never
/// confirms it.
struct ExperimentalHardwareSheet: View {
  let model: String
  let warnings: [String]
  let onConfirm: (ExperimentalHardwareLevel, String) -> Void
  let onCancel: () -> Void

  @State private var level: ExperimentalHardwareLevel = .bootloaderOnly
  @State private var typed = ""

  private var confirmed: Bool {
    ExperimentalHardwareConsent(level: level, typed: typed) != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(PlainLanguage.experimentalTitle)
        .font(InstallerTheme.sheetTitle)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
      Text(model)
        .font(InstallerTheme.body)
        .foregroundStyle(InstallerTheme.secondaryText)
        .padding(.bottom, 14)
      ForEach(PlainLanguage.experimentalWarning, id: \.self) { line in
        Text(line)
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 8)
      }
      Picker("", selection: $level) {
        ForEach(ExperimentalHardwareLevel.allCases, id: \.self) { choice in
          Text(PlainLanguage.experimentalLevelTitle(choice)).tag(choice)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .padding(.vertical, 8)
      Text(PlainLanguage.experimentalLevelDetail(level))
        .font(InstallerTheme.body)
        .foregroundStyle(InstallerTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
      if !warnings.isEmpty {
        Text(warnings.joined(separator: "\n"))
          .font(InstallerTheme.body)
          .foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 12)
      }
      Text(PlainLanguage.experimentalConfirmPrompt)
        .font(InstallerTheme.body)
        .padding(.bottom, 6)
      TextField(ExperimentalHardwareConsent.phrase, text: $typed)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .padding(.bottom, 28)
      HStack(spacing: 16) {
        Spacer(minLength: 0)
        Button(PlainLanguage.cancel, action: onCancel)
          .auroraSecondaryButton(size: .large)
          .keyboardShortcut(.cancelAction)
        Button(PlainLanguage.experimentalConfirmAction) { onConfirm(level, typed) }
          .auroraPrimaryButton(size: .large)
          .disabled(!confirmed)
      }
    }
    .padding(32)
    .frame(width: 560)
    .auroraTypography()
    .foregroundStyle(InstallerTheme.text)
    .background(InstallerTheme.window)
  }
}
