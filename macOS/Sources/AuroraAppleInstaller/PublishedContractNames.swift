/// Names fixed by artifacts that already exist outside this source tree: the
/// payload metadata the distribution repositories publish, the Recovery
/// templates already released, and the payloads assembled from them. They
/// predate the Aurora name, so each value is a published contract and must
/// stay byte-identical; only the Swift names are Aurora's.
public enum PublishedContractNames {
  /// Payload metadata: the `os_list` key that marks the full-OS template.
  public static let osTargetKey = "omarchy_target"
  /// Payload metadata: the only value `osTargetKey` may have.
  public static let fullOSTarget = "apple-silicon-full-os"
  /// Payload metadata: the `recovery_gui` value that selects the native
  /// Recovery app.
  public static let nativeRecoveryGUI = "omarchy-native-v1"
  /// The volume icon name payloads declared before per-distribution icons.
  public static let legacyVolumeIcon = "omarchy-volume.icns"
  /// The released Recovery app's executable.
  public static let recoveryExecutableName = "OmarchyRecovery"
  /// The Recovery app's executable, relative to its bundle.
  public static let recoveryExecutablePath = "Contents/MacOS/" + recoveryExecutableName
  /// The Recovery app's Info.plist marker for its build mode.
  public static let recoveryBuildModeKey = "OmarchyRecoveryBuildMode"
  /// The Recovery app's Info.plist marker for its install-data layout.
  public static let recoveryDataLayoutKey = "OmarchyRecoveryDataLayout"
  /// The Recovery app's inventory manifest, shipped beside it in payloads.
  public static let recoveryManifestName = "omarchy-recovery-app.json"
}
