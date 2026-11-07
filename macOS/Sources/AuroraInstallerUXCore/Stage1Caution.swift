#if os(macOS)
  import Darwin
  import Foundation

  /// Supported Macs on which aura's Stage 1 is untried or known to be
  /// limited. The owner is told before installing and can still go ahead.
  /// This mirrors scripts/supported-models.json `stage1_caution`; a test
  /// keeps them equal. The M1 Pro, Max and Ultra are no longer listed:
  /// their iBoot refused aura 1.0.0b1's 4.39 MB Stage 1, and aura's
  /// 1.6 MB Stage 1 is under the size the M1 Pro's iBoot accepts.
  public enum Stage1Caution {
    private static let untriedChip =
      "aura 1.0.0b1 runs the M3 Ultra (T6032) CPU-only, and neither its Stage 1 nor this Mac’s iBoot has been tried, so Aurora may not start."

    private static let untriedBoard =
      "Support for this 14-inch MacBook Pro is experimental: the Aurora team has not started Aurora on one yet. It shares the M4 Pro chip and aura’s Stage 1 with the tested 16-inch model, but its own board is untested, so Aurora may not start."

    private static let preliminaryOLED =
      "Support for this MacBook Pro with the OLED touchscreen is preliminary and untested on hardware. Nobody on the Aurora team has one yet. Its Linux device tree is new and untested, the touchscreen does not work yet, the glowing Apple logo is untested, and the built-in display works only as a simple boot screen until the display driver supports it. Aurora may not start."

    static let reasons: [String: String] = [
      "apple,j575d": untriedChip,
      "apple,j614s": untriedBoard,
      "apple,k114c": preliminaryOLED,
      "apple,k114s": preliminaryOLED,
      "apple,k116c": preliminaryOLED,
      "apple,k116s": preliminaryOLED,
    ]

    public static func reason(for deviceIdentifier: String) -> String? {
      reasons[deviceIdentifier.lowercased()]
    }

    /// The running Mac's caution, read once from `hw.targettype`.
    public static let thisMac: String? = {
      var size = 0
      guard sysctlbyname("hw.targettype", nil, &size, nil, 0) == 0, size > 1, size < 64 else {
        return nil
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("hw.targettype", &bytes, &size, nil, 0) == 0 else { return nil }
      let target = String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        .lowercased()
      return reason(for: target.hasPrefix("apple,") ? target : "apple," + target)
    }()
  }
#endif
