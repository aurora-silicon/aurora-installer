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
  private static let markSpacing: CGFloat = 10
  private static let deviceSymbolSpacing: CGFloat = 14
  private static let markSize: CGFloat = 32
  /// AuroraLogo.png's artwork starts 164 of 1024 pixels in; pulling the mark
  /// left by that margin puts the visible logo on the page column's edge.
  private static let markInset = markSize * 164 / 1024

  var body: some View {
    HStack(spacing: 16) {
      HStack(spacing: Self.markSpacing) {
        AuroraMark().frame(width: Self.markSize, height: Self.markSize)
        Text(distribution?.title ?? "Aurora").font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
      }
      .padding(.leading, -Self.markInset)
      Spacer(minLength: 16)
      HStack(spacing: Self.deviceSymbolSpacing) {
        Image(systemName: device.symbol).font(.system(size: 23, weight: .regular))
          .frame(width: 30, height: 30)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(device.name).font(.system(size: 12, weight: .medium))
          if let chip = device.chip {
            Text(chip).font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      }
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundStyle(.primary)
  }
}
