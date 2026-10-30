#if os(macOS)
  import Darwin
  import Foundation

  /// Supported Macs whose iBoot may refuse aura's 4.39 MB raw Stage 1. The
  /// owner is told before installing and can still go ahead. This mirrors
  /// scripts/supported-models.json `stage1_caution`; a test keeps them equal.
  public enum Stage1Caution {
    private static let refusedOnJ316s =
      "On the 16-inch M1 Pro (J316s) iBoot refuses aura 1.0.0b1’s 4,390,912-byte Stage 1 and shows “macOS needs to be reinstalled” instead of starting Aurora. A smaller 4,063,232-byte build is refused too."
    private static let sameGeneration =
      "This Mac uses the same iBoot generation as the 16-inch M1 Pro, where iBoot refuses aura 1.0.0b1’s 4,390,912-byte Stage 1. It has not been tried on this model, so Aurora may not start."

    static let reasons: [String: String] = [
      "apple,j314s": refusedOnJ316s,
      "apple,j316s": refusedOnJ316s,
      "apple,j314c": sameGeneration,
      "apple,j316c": sameGeneration,
      "apple,j375c": sameGeneration,
      "apple,j375d": sameGeneration,
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
