import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

struct MacHeaderDisplay {
  let name: String
  let chip: String?
  let symbol: String
  let powerButtonGuide: MacPowerButtonGuide

  static let unknown = MacHeaderDisplay(
    name: "Mac", chip: nil, symbol: "desktopcomputer", powerButtonGuide: .generic)
  static let simulation = MacHeaderDisplay(
    name: "MacBook Neo", chip: "Apple A18 Pro", symbol: "laptopcomputer",
    powerButtonGuide: .notebook)

  static func inspect(isSimulation: Bool) -> MacHeaderDisplay {
    if isSimulation { return .simulation }
    guard let identity = try? AppleSiliconHostInspector().inspectIdentity() else { return .unknown }
    let family = MacModelNames.entry(for: identity.deviceIdentifier)?.family
    let symbol: String
    switch family {
    case "MacBook Air", "MacBook Pro", "MacBook Neo": symbol = "laptopcomputer"
    case "Mac mini": symbol = "macmini"
    case "Mac Studio": symbol = "macstudio"
    default: symbol = "desktopcomputer"
    }
    return MacHeaderDisplay(
      name: family ?? "Mac", chip: identity.chip, symbol: symbol,
      powerButtonGuide: MacPowerButtonGuide(
        deviceIdentifier: identity.deviceIdentifier, modelIdentifier: identity.model))
  }
}

struct InstallerMasthead: View {
  var distribution: AuroraDistribution? = nil
  let device: MacHeaderDisplay
  var channel: ReleaseChannel? = nil
  /// The plan on screen is a Reset or boot loader update, which names its
  /// channel whichever it is.
  var existingInstallation = false
  private static let markSpacing: CGFloat = 10
  private static let titleSize: CGFloat = 17
  private static let channelSpacing: CGFloat = 8
  private static let deviceSymbolSpacing: CGFloat = 14
  private static let markSize: CGFloat = 32
  /// AuroraLogo.png's artwork starts 164 of 1024 pixels in; pulling the mark
  /// left by that margin puts the visible logo on the page column's edge.
  private static let markInset = markSize * 164 / 1024

  var body: some View {
    HStack(spacing: Space.l) {
      HStack(spacing: Self.markSpacing) {
        AuroraMark().frame(width: Self.markSize, height: Self.markSize)
        HStack(alignment: .firstTextBaseline, spacing: Self.channelSpacing) {
          Text(distribution?.title ?? "Aurora")
            .font(.system(size: Self.titleSize, weight: .semibold))
            .lineLimit(1)
          if let label = PlainLanguage.mastheadChannelLabel(
            channel, existingInstallation: existingInstallation)
          {
            // The title's size in the secondary colour, on its baseline. A long
            // title truncates before the channel name does.
            Text(label)
              .font(.system(size: Self.titleSize))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
      .padding(.leading, -Self.markInset)
      Spacer(minLength: 16)
      HStack(spacing: Self.deviceSymbolSpacing) {
        Image(systemName: device.symbol).font(.system(size: 23, weight: .regular))
          .frame(width: 30, height: 30)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Space.xxs) {
          Text(device.name).font(InstallerTheme.detail.weight(.medium))
          if let chip = device.chip {
            Text(chip).font(InstallerTheme.caption).foregroundStyle(.secondary)
          }
        }
      }
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundStyle(.primary)
  }
}
