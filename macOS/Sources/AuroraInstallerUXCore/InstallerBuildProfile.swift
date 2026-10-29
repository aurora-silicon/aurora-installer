#if os(macOS)
  import Foundation
  import AuroraAppleInstallerTrustCore

  /// Private capability and state isolation are separate from encryption choice.
  public enum InstallerBuildProfile: Equatable, Sendable {
    case standard
    case privatePlain
    case privateLimine
    /// For bring-up teams: its sealed catalog may admit Macs the public
    /// catalogs don't, so its state never mixes with theirs.
    case developer

    public static var current: Self {
      resolve(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public static func resolve(infoDictionary: [String: Any]) -> Self {
      // Preserve the restrictive legacy flag if an invalid bundle contains both.
      if infoDictionary["AuroraPrivatePlainTest"] as? Bool == true {
        return .privatePlain
      }
      if infoDictionary["AuroraPrivateLimineTest"] as? Bool == true {
        return .privateLimine
      }
      if infoDictionary["AuroraDeveloperBuild"] as? Bool == true {
        return .developer
      }
      return .standard
    }

    public var allowsEncryption: Bool { self != .privatePlain }
    public var showsReleaseChannels: Bool { self == .standard }

    public var workspaceName: String {
      switch self {
      case .standard: InstallerProductIdentity.appIdentifier
      case .privatePlain: InstallerProductIdentity.appIdentifier + ".private-m3-20260922"
      case .privateLimine: InstallerProductIdentity.appIdentifier + ".private-limine-20260922"
      case .developer: InstallerProductIdentity.appIdentifier + ".developer"
      }
    }

    public var startupSequence: String {
      switch self {
      case .standard, .privateLimine, .developer: "aura → U-Boot → Limine → Aurora"
      case .privatePlain: "aura → U-Boot → GRUB → Aurora"
      }
    }
  }
#endif
