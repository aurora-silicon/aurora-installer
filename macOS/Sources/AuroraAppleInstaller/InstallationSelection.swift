import Foundation

public enum AuroraDistribution: String, CaseIterable, Codable, Identifiable, Sendable {
  case fedora, arch, nixos, omarchy, debian
  public static var installable: [Self] {
    var distributions: [Self] = [.fedora, .arch, .nixos, .debian]
    #if AURORA_ENABLE_OMARCHY
      distributions.append(.omarchy)
    #endif
    return distributions
  }

  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .fedora: "Aurora Fedora Remix"
    case .arch: "Aurora Alarm"
    case .nixos: "Aurora NixOS"
    case .omarchy: "Omarchy Aurora"
    case .debian: "Aurora, based on Debian testing"
    }
  }
  /// Names earlier installers gave these installations. Erase Linux and
  /// reinstall still recognize them.
  public static let legacyTitles = ["Fedora Aurora Remix", "Aurora ALARM"]
  public var supportsDesktop: Bool { true }
  public var availableDesktops: [AuroraDesktop] {
    self == .omarchy ? [.hyprland] : [.kde, .gnome, .minimal]
  }
}

public enum AuroraDesktop: String, CaseIterable, Codable, Identifiable, Sendable {
  case kde, gnome, minimal, hyprland
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .kde: "KDE Plasma"
    case .gnome: "GNOME"
    case .minimal: "Minimal (shell)"
    case .hyprland: "Hyprland"
    }
  }
}

/// The profile is bound to a distinct signed catalog, payload and staging area.
/// Each distribution exposes only the desktops its signed profiles offer.
public struct AuroraInstallationSelection: Equatable, Codable, Sendable {
  public var distribution: AuroraDistribution
  public var desktop: AuroraDesktop

  public init(distribution: AuroraDistribution = .fedora, desktop: AuroraDesktop? = nil) {
    self.distribution = distribution
    self.desktop = desktop ?? distribution.availableDesktops[0]
  }

  public var effectiveDesktop: AuroraDesktop? {
    distribution.availableDesktops.contains(desktop) ? desktop : nil
  }
  public var profileID: String {
    distribution.rawValue + "-" + desktop.rawValue
  }
  public var summary: String {
    distribution.title + " · " + desktop.title
  }
  public static var allProfileIDs: Set<String> {
    Set(
      AuroraDistribution.installable.flatMap { distribution in
        distribution.availableDesktops.map {
          AuroraInstallationSelection(distribution: distribution, desktop: $0).profileID
        }
      })
  }

  public mutating func selectDistribution(_ distribution: AuroraDistribution) {
    self.distribution = distribution
    if !distribution.availableDesktops.contains(desktop) {
      desktop = distribution.availableDesktops[0]
    }
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let distribution = try values.decode(AuroraDistribution.self, forKey: .distribution)
    let desktop = try values.decode(AuroraDesktop.self, forKey: .desktop)
    guard distribution.availableDesktops.contains(desktop) else {
      throw DecodingError.dataCorruptedError(
        forKey: .desktop, in: values, debugDescription: "Unsupported distribution and desktop pair")
    }
    self.init(distribution: distribution, desktop: desktop)
  }

  public func requireMatchingProfile(_ profileID: String?) throws {
    guard effectiveDesktop != nil, profileID == self.profileID,
      AuroraDistribution.installable.contains(distribution)
    else {
      throw AuroraProfileError.selectionMismatch
    }
  }
}

public enum AuroraProfileError: LocalizedError {
  case selectionMismatch
  case unavailable(String)
  public var errorDescription: String? {
    switch self {
    case .selectionMismatch:
      "The release does not match the selected system and desktop. No installation was started."
    case .unavailable(let title):
      "An installation image for \(title) is not included in this build."
    }
  }
}
