#if DEBUG
  import OmarchyAppleInstallerTrustCore
  import OmarchyInstallerUXCore
  import SwiftUI

  /// Component render fixtures only. This view creates no installer environment,
  /// credentials, helper connection, downloads or disk operations.
  struct InstallerVisualPreview: View {
    let screen: String
    @State private var allocation: UInt64 = 128_000_000_000

    private var plan: PlanDisplay {
      PlanDisplay(
        diskTotalBytes: 512_000_000_000, omarchyBytes: allocation,
        bindingDigest: String(repeating: "a", count: 64), minimumBytes: 32_000_000_000,
        maximumBytes: 192_000_000_000, fixedMacOSBytes: 320_000_000_000)
    }

    var body: some View {
      Group {
        if screen == "chooser" {
          AuroraWelcomeView(selection: .constant(AuroraInstallationSelection()), onContinue: {})
        } else {
          InstallerPageLayout {
            VStack(alignment: .leading, spacing: 6) {
              Text("Fedora Aurora Remix · KDE Plasma").font(.system(size: 15, weight: .medium))
              Text("Apple A18 Pro · Internal storage").font(OmarchyTheme.detail).foregroundStyle(
                .secondary)
            }
          } content: {
            VStack(alignment: .leading, spacing: 18) {
              stage
            }
          } actions: {
            if screen == "allocation" {
              Button("Install Aurora", action: {}).omarchyPrimaryButton().disabled(true)
            } else {
              Text("Keep this Mac open and plugged in.")
                .font(OmarchyTheme.detail).foregroundStyle(.secondary)
            }
          }
        }
      }
      .foregroundStyle(OmarchyTheme.text).background(OmarchyTheme.window)
      .preferredColorScheme(CommandLine.arguments.contains("--preview-dark") ? .dark : .light)
    }

    @ViewBuilder private var stage: some View {
      switch screen {
      case "allocation":
        DiskSplitPanel(plan: plan, editable: true, isBusy: false, onSizeChosen: { allocation = $0 })
        EncryptDiskToggle(isOn: true, enabled: true, onChange: { _ in })
        Toggle(PlainLanguage.planAcknowledgement(resizesMacOS: false), isOn: .constant(false))
          .toggleStyle(.checkbox).font(OmarchyTheme.body)
      case "loading":
        PreparationStatusPanel(detail: PlainLanguage.inspectingSubheadline)
      case "download":
        DownloadPanel(
          update: AssetProgressUpdate(
            stage: .downloading,
            rows: [
              AssetProgressRow(
                role: "payload", fileName: "fedora-kde.zip", bytesCompleted: 1_520_000_000,
                totalBytes: 4_280_000_000, phase: .downloading)
            ]))
      case "install":
        InstallPanel(
          progress: InstallProgressDisplay(
            phaseTitle: "Writing boot files…", stageIndex: 1, stageFractions: [1, 0, 0],
            stageLabels: PlainLanguage.installStageLabels, feed: [], degraded: false,
            startedAt: Date().addingTimeInterval(-83)))
      default:
        ContentUnavailableView("Unknown visual preview", systemImage: "questionmark")
      }
    }
  }
#endif
