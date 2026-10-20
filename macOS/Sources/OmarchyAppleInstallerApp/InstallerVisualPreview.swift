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
      let source: PlanAllocationSource =
        screen == "allocation-other"
        ? .otherContainerResize
        : (screen == "allocation-free" ? .freeExtent : .macOSResize)
      let macOS: UInt64 = source == .macOSResize ? 400_000_000_000 : 256_000_000_000
      let other: UInt64 = source == .otherContainerResize ? 208_000_000_000 : 64_000_000_000
      return PlanDisplay(
        diskTotalBytes: 512_000_000_000, omarchyBytes: allocation,
        bindingDigest: String(repeating: "a", count: 64), minimumBytes: 32_000_000_000,
        maximumBytes: source == .otherContainerResize ? 160_000_000_000 : 192_000_000_000,
        targetDescription: source == .otherContainerResize
          ? "Internal storage · Resize Work"
          : (source == .freeExtent
            ? "Internal storage · Use free space" : "Internal storage · Resize macOS"),
        fixedMacOSBytes: source == .macOSResize ? nil : macOS,
        allocationSource: source, baselineMacOSBytes: macOS, otherAllocatedBytes: other)
    }

    var body: some View {
      Group {
        if screen == "chooser" {
          AuroraWelcomeView(
            selection: .constant(AuroraInstallationSelection()), device: .simulation, onContinue: {}
          )
        } else {
          InstallerPageLayout(showsFooter: screen != "loading") {
            InstallerMasthead(distribution: .fedora, device: .simulation)
          } content: {
            VStack(alignment: .leading, spacing: 16) {
              stage
            }
          } actions: {
            if screen.hasPrefix("allocation") {
              Button("Install Aurora", action: {}).omarchyPrimaryButton().disabled(true)
            } else {
              Text("Keep this Mac open and plugged in.")
                .font(OmarchyTheme.detail).foregroundStyle(.secondary)
            }
          }
        }
      }
      .foregroundStyle(OmarchyTheme.text).background(OmarchyTheme.window)
    }

    @ViewBuilder private var stage: some View {
      switch screen {
      case "allocation", "allocation-free", "allocation-other":
        DiskSplitPanel(plan: plan, editable: true, isBusy: false, onSizeChosen: { allocation = $0 })
        EncryptDiskToggle(isOn: true, enabled: true, onChange: { _ in })
        Toggle(
          PlainLanguage.planAcknowledgement(resizesMacOS: plan.allocationSource != .freeExtent),
          isOn: .constant(false)
        )
        .toggleStyle(.checkbox).font(OmarchyTheme.body)
      case "loading":
        PreparationStatusPanel()
      case "preparing":
        DownloadPanel(update: AssetProgressUpdate(stage: .planning))
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
