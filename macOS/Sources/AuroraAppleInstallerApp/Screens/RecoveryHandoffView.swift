import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

struct RecoveryHandoffView: View {
  let volumeName: String
  var session: InstallerSession? = nil
  var selection = AuroraInstallationSelection()
  var device: MacHeaderDisplay = .unknown
  var onReinstall: (() -> Void)? = nil
  @State private var busy = false
  @State private var failure: String?
  @State private var showingShutdownPreview = false
  @State private var showingFailure = false
  @State private var showingDetails = false
  @State private var shutdownConfirmed = false
  private var guide: MacPowerButtonGuide {
    let restoredGuide = session?.powerButtonGuide ?? .generic
    return restoredGuide == .generic ? device.powerButtonGuide : restoredGuide
  }

  var body: some View {
    InstallerPageLayout {
      InstallerMasthead(distribution: selection.distribution, device: device)
    } content: {
      VStack(alignment: .leading, spacing: 20) {
        Text("Start in Recovery").font(InstallerTheme.title)
        HStack(spacing: 22) {
          if let name = guide.assetName,
            let url = Bundle.main.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
          {
            Image(nsImage: image)
              .resizable().interpolation(.high).scaledToFit()
              .frame(width: 242, height: 160)
              .accessibilityLabel(guide.location)
          } else {
            VStack(spacing: 12) {
              Image(systemName: "power").font(.system(size: 64, weight: .light))
              Text(guide.location).font(InstallerTheme.detail).multilineTextAlignment(.center)
            }.frame(width: 242, height: 160)
          }
          VStack(alignment: .leading, spacing: 18) {
            step(1, "Shut down completely.")
            step(2, guide.holdInstruction)
            step(3, "Choose “\(volumeName)” → Finish Installation.")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Don’t restart normally yet: unfinished setup can cause a boot loop.")
          .font(InstallerTheme.detail).foregroundStyle(InstallerTheme.caution)
        Text("Have your macOS owner’s password ready. You’ll create your recovery account there.")
          .font(InstallerTheme.detail).foregroundStyle(InstallerTheme.secondaryText)
      }.font(InstallerTheme.body)
    } actions: {
      HStack(spacing: 12) {
        if let onReinstall {
          Button("Reset options…", action: onReinstall)
            .auroraSecondaryButton()
            .disabled(busy)
        }
        NativeSpinner().controlSize(.small)
          .frame(width: 16, height: 16).opacity(busy ? 1 : 0)
          .accessibilityHidden(!busy).accessibilityLabel("Preparing shutdown")
        Button(shutdownConfirmed ? "Yes, I have read, shut down" : "Shut down", action: shutDown)
          .auroraPrimaryButton().disabled(busy)
        Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
      }
    }
    .foregroundStyle(InstallerTheme.text)
    .alert("Shut Down", isPresented: $showingShutdownPreview) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The installed flow shuts down here. This simulation keeps your Mac running.")
    }
    .alert("Couldn’t prepare shutdown", isPresented: $showingFailure) {
      Button("Show details") { showingDetails = true }
      Button("OK", role: .cancel) {}
    } message: {
      Text("The startup setup needs attention before you shut down.")
    }
    .sheet(isPresented: $showingDetails) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Shutdown details").font(.headline)
        Text(failure ?? "").textSelection(.enabled).lineLimit(10).truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Button("Copy details") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failure ?? "", forType: .string)
          }
          Spacer()
          Button("Done") { showingDetails = false }
        }
      }.padding(24).frame(width: 520, height: 280)
    }
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(String(number)).font(InstallerTheme.detail.weight(.semibold))
        .foregroundStyle(InstallerTheme.secondaryText)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func shutDown() {
    guard shutdownConfirmed else {
      shutdownConfirmed = true
      return
    }
    guard let session else {
      showingShutdownPreview = true
      return
    }
    busy = true
    failure = nil
    Task { @MainActor in
      defer { busy = false }
      do {
        let accepted = try await session.prepareRecoveryHandoffAndShutdown()
        if !accepted {
          failure = "Choose Apple menu → Shut Down after saving your work."
          showingFailure = true
        }
      } catch {
        failure = error.localizedDescription
        showingFailure = true
      }
    }
  }
}
