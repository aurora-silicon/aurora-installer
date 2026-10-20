import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

struct MacHeaderDisplay {
  let name: String
  let chip: String?
  let symbol: String

  static let unknown = MacHeaderDisplay(name: "Mac", chip: nil, symbol: "desktopcomputer")
  static let simulation = MacHeaderDisplay(
    name: "MacBook Neo", chip: "Apple A18 Pro", symbol: "laptopcomputer")

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
    return MacHeaderDisplay(name: family ?? "Mac", chip: identity.chip, symbol: symbol)
  }
}

struct InstallerMasthead: View {
  var distribution: AuroraDistribution? = nil
  let device: MacHeaderDisplay
  private static let markSpacing: CGFloat = 10

  var body: some View {
    HStack(spacing: 16) {
      HStack(spacing: Self.markSpacing) {
        if let distribution {
          DistributionMark(distribution: distribution).frame(width: 30, height: 30)
        } else {
          AuroraMark().frame(width: 32, height: 32)
        }
        Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
      }
      Spacer(minLength: 16)
      HStack(spacing: Self.markSpacing) {
        VStack(alignment: .trailing, spacing: 2) {
          Text(device.name).font(.system(size: 12, weight: .medium))
          if let chip = device.chip {
            Text(chip).font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
        Image(systemName: device.symbol).font(.system(size: 23, weight: .regular))
          .frame(width: 30, height: 30)
          .accessibilityHidden(true)
      }
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundStyle(.primary)
  }

  private var title: String {
    switch distribution {
    case .some(.fedora): "Aurora Fedora Remix"
    case .some(.arch): "Aurora ALARM"
    case .some(.nixos): "Aurora NixOS"
    case nil: "Aurora Linux"
    }
  }
}

struct DistributionMark: View {
  let distribution: AuroraDistribution

  var body: some View {
    BrandImage(asset).accessibilityLabel(distribution.title)
  }

  private var asset: String {
    switch distribution {
    case .fedora: "Fedora"
    case .arch: "ArchLinuxARM"
    case .nixos: "NixOS"
    }
  }
}
