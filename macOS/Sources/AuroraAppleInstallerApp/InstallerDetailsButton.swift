import AppKit
import AuroraInstallerUXCore
import SwiftUI

/// Details stay in a compact prompt instead of expanding the installer page.
struct InstallerDetailsButton: View {
  let title: String
  let text: String
  @State private var presented = false

  var body: some View {
    Button(title) { presented = true }
      .buttonStyle(.plain).font(InstallerTheme.detail).foregroundStyle(.secondary)
      .sheet(isPresented: $presented) {
        VStack(alignment: .leading, spacing: 16) {
          Text(title).font(.headline)
          Text(text).font(InstallerTheme.technical).textSelection(.enabled)
            .lineLimit(12).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 12) {
            Button("Copy details") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
            }.auroraSecondaryButton(size: .large)
            Spacer()
            Button("Done") { presented = false }
              .auroraPrimaryButton(size: .large).keyboardShortcut(.defaultAction)
          }
        }
        .padding(24).frame(width: 520)
        .foregroundStyle(InstallerTheme.text).background(InstallerTheme.window)
      }
  }
}
