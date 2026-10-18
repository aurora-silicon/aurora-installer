import Foundation

public enum AuroraDistribution: String, CaseIterable, Codable, Identifiable, Sendable {
  case fedora, arch, uefi
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .fedora: "Fedora Aurora Remix"
    case .arch: "Aurora ALARM"
    case .uefi: "UEFI"
    }
  }
  public var supportsDesktop: Bool { self != .uefi }
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
/// A UEFI-only install never carries a desktop choice into an execution plan.
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
    effectiveDesktop.map { distribution.rawValue + "-" + $0.rawValue } ?? "uefi"
  }
  public var summary: String {
    effectiveDesktop.map { distribution.title + " · " + $0.title } ?? "UEFI boot environment"
  }
  public static var allProfileIDs: Set<String> {
    Set(
      AuroraDistribution.allCases.flatMap { distribution in
        distribution.supportsDesktop
          ? AuroraDesktop.allCases.map {
            AuroraInstallationSelection(distribution: distribution, desktop: $0).profileID
          } : ["uefi"]
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
