import Foundation

public enum AuroraDistribution: String, CaseIterable, Codable, Identifiable, Sendable {
  case fedora, arch, nixos
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .fedora: "Fedora Aurora Remix"
    case .arch: "Aurora ALARM"
    case .nixos: "Aurora NixOS"
    }
  }
  /// What the installer shows. Upstream names appear only as their trademark
  /// terms allow: Fedora's Remix mark, and "based on" for Arch Linux ARM and
  /// NixOS. `title` stays the installed volume's name, which other code matches.
  public var displayName: String {
    switch self {
    case .fedora: "Fedora Remix"
    case .arch: "Based on Arch Linux ARM"
    case .nixos: "Based on NixOS"
    }
  }
  public var supportsDesktop: Bool { true }
}

public enum AuroraDesktop: String, CaseIterable, Codable, Identifiable, Sendable {
  case kde, gnome, minimal
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .kde: "KDE Plasma"
    case .gnome: "GNOME"
    case .minimal: "Minimal (shell)"
    }
  }
}

/// The profile is bound to a distinct signed catalog, payload and staging area.
/// Each distribution offers the same explicit desktop choices.
public struct AuroraInstallationSelection: Equatable, Codable, Sendable {
  public var distribution: AuroraDistribution
  public var desktop: AuroraDesktop

  public init(distribution: AuroraDistribution = .fedora, desktop: AuroraDesktop = .kde) {
    self.distribution = distribution
    self.desktop = desktop
  }

  public var effectiveDesktop: AuroraDesktop? {
    distribution.supportsDesktop ? desktop : nil
  }
  public var profileID: String {
    distribution.rawValue + "-" + desktop.rawValue
  }
  public var summary: String {
    "Aurora (" + distribution.displayName + ") · " + desktop.title
  }
  public static var allProfileIDs: Set<String> {
    Set(
      AuroraDistribution.allCases.flatMap { distribution in
        AuroraDesktop.allCases.map {
          AuroraInstallationSelection(distribution: distribution, desktop: $0).profileID
        }
      })
  }

  public func requireMatchingProfile(_ profileID: String?) throws {
    guard profileID == self.profileID else { throw AuroraProfileError.selectionMismatch }
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
