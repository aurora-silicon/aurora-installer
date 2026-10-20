import AppKit
import OmarchyInstallerUXCore
import SwiftUI

/// Details stay in a compact prompt instead of expanding the installer page.
struct InstallerDetailsButton: View {
  let title: String
  let text: String
  @State private var presented = false

  var body: some View {
    Button(title) { presented = true }
      .buttonStyle(.plain).font(OmarchyTheme.detail).foregroundStyle(.secondary)
      .sheet(isPresented: $presented) {
        VStack(alignment: .leading, spacing: 16) {
          Text(title).font(.headline)
          Text(text).font(OmarchyTheme.technical).textSelection(.enabled)
            .lineLimit(12).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 12) {
            Button("Copy details") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
            }.omarchySecondaryButton()
            Spacer()
            Button("Done") { presented = false }
              .omarchyPrimaryButton().keyboardShortcut(.defaultAction)
          }
        }
        .padding(24).frame(width: 520)
        .foregroundStyle(OmarchyTheme.text).background(OmarchyTheme.window)
      }
  }
}
