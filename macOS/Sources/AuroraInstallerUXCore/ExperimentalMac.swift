#if os(macOS)
  import Darwin
  import Foundation

  /// Supported Macs whose support is experimental: their startup code or
  /// installer composition has not been qualified. The owner sees one short,
  /// generic note on the plan (the same for every such Mac) and can still go
  /// ahead. This mirrors scripts/supported-models.json `stage1_caution`; a
  /// test keeps them equal. Per-Mac details live in that file and the docs,
  /// never in the app.
  public enum ExperimentalMac {
    static let boards: Set<String> = [
      "apple,j575d",
      "apple,j614s",
      "apple,j616c",
      "apple,j604",
      "apple,j623",
      "apple,j624",
      "apple,j715",
      "apple,j773g",
      "apple,j614c",
      "apple,j773s",
      "apple,j575c",
      "apple,j516s",
      "apple,j813",
      "apple,j873g",
      "apple,j704",
      "apple,j815",
      "apple,j804",
      "apple,j833ct",
      "apple,j714c",
      "apple,j714s",
      "apple,j716c",
      "apple,j716s",
      "apple,j775c",
      "apple,j775d",
      "apple,j873s",
      "apple,k114c",
      "apple,k114s",
      "apple,k116c",
      "apple,k116s",
    ]

    public static func isExperimental(_ deviceIdentifier: String) -> Bool {
      boards.contains(deviceIdentifier.lowercased())
    }

    /// Whether the running Mac is experimental, read once from `hw.targettype`.
    public static let thisMac: Bool = {
      var size = 0
      guard sysctlbyname("hw.targettype", nil, &size, nil, 0) == 0, size > 1, size < 64 else {
        return false
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("hw.targettype", &bytes, &size, nil, 0) == 0 else { return false }
      let target = String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        .lowercased()
      return isExperimental(target.hasPrefix("apple,") ? target : "apple," + target)
    }()
  }
#endif
