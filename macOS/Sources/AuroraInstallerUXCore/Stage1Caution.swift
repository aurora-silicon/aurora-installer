#if os(macOS)
  import Darwin
  import Foundation

  /// Supported Macs whose startup code is limited or whose installer
  /// composition is unqualified. The owner is told and can still go ahead.
  /// This mirrors scripts/supported-models.json `stage1_caution`; a test
  /// keeps them equal. The M1 Pro, Max and Ultra are no longer listed:
  /// their iBoot refused aura 1.0.0b1's 4.39 MB Stage 1, and aura's
  /// 1.6 MB Stage 1 is under the size the M1 Pro's iBoot accepts.
  public enum Stage1Caution {
    private static let untriedChip =
      "aura 1.0.0b1 runs the M3 Ultra (T6032) CPU-only, and neither its Stage 1 nor this Mac’s iBoot has been tried, so Aurora may not start."

    private static let untriedBoard =
      "Support for this 14-inch MacBook Pro is experimental: the Aurora team has not started Aurora on one yet. It shares the M4 Pro chip and aura’s Stage 1 with the tested 16-inch model, but its own board is untested, so Aurora may not start."

    private static let untriedM4Board =
      "Support for this Mac is experimental: the Aurora team has not started Aurora on one yet. It shares its M4-family chip and aura’s Stage 1 with a tested Mac, but its own board is untested, so Aurora may not start."

    private static let m4MacMini =
      "Support for the Mac mini with M4 is experimental. An earlier build of this installer completed on one, but the system it installed did not start Aurora. With the current published installer payloads, Aurora is not expected to start yet. Aurora has started on one only with changes that are still under review; with those changes, HDMI, the front USB ports and Ethernet worked. Even with those changes, the rear USB-C ports and GPU acceleration did not work."

    private static let m4MaxMacStudio =
      "Support for the Mac Studio with M4 Max is experimental. An earlier build of this installer installed Aurora on one, and it started: HDMI and USB-C displays, USB, Ethernet and GPU acceleration worked, and sound worked after a system update. If the first start after the installation shows no picture, restart the Mac once. This build has not been tried on one, so Aurora may not start."

    private static let newMaxBoard =
      "Support for the 16-inch MacBook Pro with M4 Max is experimental: Aurora has run on one, but not from this installer, and the Linux device tree this installer uses for it has not started on one yet, so Aurora may not start."

    private static let untriedM5M6 =
      "Support for this Mac is experimental: the Aurora team has not used this installer on one yet, and the current Aurora startup code has not run on it, so Aurora may not start."

    private static let describedOnly =
      "Support for this Mac is experimental and untested: nobody on the Aurora team has one yet. Its Linux device tree is new and only describes the hardware, most of which is not enabled yet, and neither aura nor this installer has run on it, so Aurora may not start."

    private static let preliminaryOLED =
      "Support for this MacBook Pro with the OLED touchscreen is preliminary and untested on hardware. Nobody on the Aurora team has one yet. Its Linux device tree is new and untested, the touchscreen does not work yet, the glowing Apple logo is untested, and the built-in display works only as a simple boot screen until the display driver supports it. Aurora may not start."

    private static let unqualifiedT6050Composition =
      "This installer and its kernel, startup code and firmware combination have not been qualified on this Mac. Its Linux device tree is present, but Aurora may not start and some hardware may not work. Continue only after acknowledging the warning and the recovery steps."

    private static let m3Pro16 =
      "Support for the 16-inch MacBook Pro with M3 Pro is experimental, and it needs macOS 27.2 or later: on an older macOS the installer asks you to update first. The Aurora team has not started Linux on one from the macOS 27.2 stub yet. Aurora's startup code and the kernel in the published downloads support only the macOS 14 version of its display and graphics firmware so far, so on the macOS 27.2 stub the built-in display works only as a simple boot screen and there is no GPU acceleration. Aurora may not start."

    private static let m5Air13 =
      "Support for the 13-inch MacBook Air with M5 is experimental, and it needs macOS 27.2 or later: on an older macOS the installer asks you to update first. The Aurora team has installed it with a test build of this installer on the macOS 27.2 stub and started Linux from its internal disk, but only with a newer U-Boot than the published downloads carry: with theirs, the Mac stops at the U-Boot prompt, and macOS stays available from Startup Options. The kernel in the published downloads does not bring up its GPU or display driver on the macOS 27.2 stub yet, so the built-in display works only as a simple boot screen, and the installer does not collect its Wi-Fi and Bluetooth firmware yet. A standard install has no GPU acceleration, display driver, Wi-Fi or Bluetooth, and Aurora may not start."

    private static let m5Air15 =
      "Support for the 15-inch MacBook Air with M5 is experimental, and it needs macOS 27.2 or later: on an older macOS the installer asks you to update first. The Aurora team has installed it with a test build of this installer on the macOS 27.2 stub, finished the installation and started Linux on it, but only with a separately built kernel. The kernel in the published downloads does not support most of its hardware yet, and the installer does not collect its Wi-Fi and Bluetooth firmware yet, so a standard install has no GPU acceleration, display driver, Wi-Fi or Bluetooth, and Aurora may not start."

    private static let m5Pro14 =
      "Support for the 14-inch MacBook Pro with M5 is experimental, and it needs macOS 27.2 or later: on an older macOS the installer asks you to update first. The Aurora team does not have one. A contributor has installed it on the macOS 27.2 stub with a development kernel. Its GPU and built-in display need Linux changes that are still under review (aurora-silicon/linux#2093) and are not in the kernel in the published downloads yet. A standard install has no GPU acceleration, and Aurora may start without the built-in display."

    static let reasons: [String: String] = [
      "apple,j575d": untriedChip,
      "apple,j614s": untriedBoard,
      "apple,j616c": newMaxBoard,
      "apple,j604": untriedM4Board,
      "apple,j623": untriedM4Board,
      "apple,j624": untriedM4Board,
      "apple,j715": untriedM4Board,
      "apple,j773g": m4MacMini,
      "apple,j614c": untriedM4Board,
      "apple,j773s": untriedM4Board,
      "apple,j575c": m4MaxMacStudio,
      "apple,j516s": m3Pro16,
      "apple,j813": m5Air13,
      "apple,j873g": untriedM5M6,
      "apple,j704": m5Pro14,
      "apple,j815": m5Air15,
      "apple,j804": describedOnly,
      "apple,j833ct": describedOnly,
      "apple,j714c": unqualifiedT6050Composition,
      "apple,j714s": unqualifiedT6050Composition,
      "apple,j716c": unqualifiedT6050Composition,
      "apple,j716s": unqualifiedT6050Composition,
      "apple,j775c": unqualifiedT6050Composition,
      "apple,j775d": unqualifiedT6050Composition,
      "apple,j873s": unqualifiedT6050Composition,
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
