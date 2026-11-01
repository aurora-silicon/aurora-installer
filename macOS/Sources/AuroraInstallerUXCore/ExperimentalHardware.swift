#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import Foundation

  /// Whether the experimental hardware path may be offered on this Mac.
  public enum ExperimentalHardwareAvailability: Equatable, Sendable {
    /// Not checked yet, or this build cannot check.
    case unavailable
    /// This Mac is supported: the path is never offered.
    case supported
    /// Known to fail on this hardware, with the reason shown to the owner.
    case refused(String)
    /// A Mac this release does not support, and nothing known blocks it.
    case offered(model: String, warnings: [String])
  }

  /// The owner's typed agreement. A click is never enough: the phrase must be
  /// typed, so the choice cannot be made by accident or by a stray Return.
  public struct ExperimentalHardwareConsent: Equatable, Sendable {
    public static let phrase = "install on untested hardware"
    public let level: ExperimentalHardwareLevel

    public init?(level: ExperimentalHardwareLevel, typed: String) {
      let words = typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard words == Self.phrase else { return nil }
      self.level = level
    }
  }

  /// A bring-up report saved on this Mac for the owner to share.
  public struct ExperimentalBringUpReportDisplay: Equatable, Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
      self.path = path
      self.text = text
    }
  }
#endif
