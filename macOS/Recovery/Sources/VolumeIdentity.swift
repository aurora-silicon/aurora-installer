import Foundation

/// Every Aurora startup volume carries the Aurora icon, which the window
/// already shows, so Recovery leaves that volume's icon and name out.
enum VolumeIdentity {
  static func showsVolume(icon: Data?, auroraMark: Data?) -> Bool {
    guard let icon, let auroraMark, !icon.isEmpty else { return true }
    return icon != auroraMark
  }
}
