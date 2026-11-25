import Foundation

/// What Recovery reads about this Mac and its startup volume before an
/// in-place upgrade changes anything (StubUpgradeCheck).
public struct StubUpgradeFacts {
  /// The APFS volume group of the System volume this app runs from.
  public var group: String
  public var chipID: UInt64?
  /// This Mac's device class (IODeviceTree compatible), e.g. "j413ap".
  public var deviceClass: String?
  /// The EFI partition the request names, as found on this stub's disk: nil
  /// when there is none, it isn't an EFI partition or it is on another disk.
  public var espPartitionUUID: String?
  /// `aurora/upgrade/request.json` on that partition.
  public var espRequest: Data?
  /// `asahi/stub_info.json` on that partition.
  public var stubInfo: Data?
  public var espFreeBytes: UInt64
  /// The system firmware version (IODeviceTree:/chosen system-firmware-version).
  public var systemFirmware: String?
  /// The staged Stage 1 (UpgradeData/stage1/aura-boot.macho).
  public var stage1: Data?
  /// Free bytes in the stub's APFS container.
  public var containerFreeBytes: UInt64
  /// Bytes the stub's current Recovery image takes (0 when there is none).
  public var recoveryImageBytes: UInt64
  /// Whether removing it gives its blocks back: no attached disk image
  /// holds it open.
  public var recoveryImageReleasable: Bool
  public var systemVersionVisible: Bool
  public var systemVersionHidden: Bool
  /// `.IAPhysicalMedia` is there and opens Aurora Installer.app.
  public var launchedByMarker: Bool

  public init(
    group: String, chipID: UInt64?, deviceClass: String?, espPartitionUUID: String?,
    espRequest: Data?, stubInfo: Data?, espFreeBytes: UInt64, systemFirmware: String?,
    stage1: Data?, containerFreeBytes: UInt64, recoveryImageBytes: UInt64,
    recoveryImageReleasable: Bool, systemVersionVisible: Bool, systemVersionHidden: Bool,
    launchedByMarker: Bool
  ) {
    self.group = group
    self.chipID = chipID
    self.deviceClass = deviceClass
    self.espPartitionUUID = espPartitionUUID
    self.espRequest = espRequest
    self.stubInfo = stubInfo
    self.espFreeBytes = espFreeBytes
    self.systemFirmware = systemFirmware
    self.stage1 = stage1
    self.containerFreeBytes = containerFreeBytes
    self.recoveryImageBytes = recoveryImageBytes
    self.recoveryImageReleasable = recoveryImageReleasable
    self.systemVersionVisible = systemVersionVisible
    self.systemVersionHidden = systemVersionHidden
    self.launchedByMarker = launchedByMarker
  }
}

/// The checks an in-place startup firmware upgrade passes before Recovery
/// changes anything (UPGRADE-FLOW.md, sections 4.2 step 1 and 7): the request
/// against this volume group, chip, board and EFI partition, the request on
/// the EFI partition, the system firmware floor, the staged Stage 1, Apple's
/// image against the pin (RestoreImageStubPlan) and the space the swap needs.
public enum StubUpgradeCheck {
  public enum Refusal: Error, Equatable, LocalizedError {
    case notStaged
    case notLaunched
    case otherVolume
    case otherMac
    case otherPartition
    case requestDiffers
    case noStubInfo
    case firmwareFloor(have: String, need: String)
    case stage1Changed
    case versionMetadata
    case imageDiffers
    case space(need: UInt64, free: UInt64)
    case partitionFull

    public var errorDescription: String? {
      let unchanged = " Nothing was changed."
      switch self {
      case .notStaged:
        return "No startup firmware upgrade is staged on this volume." + unchanged
      case .notLaunched:
        return "This volume's Recovery wasn't opened for an upgrade. Stage it again from Linux."
          + unchanged
      case .otherVolume:
        return
          "The staged upgrade belongs to another startup volume. Shut down, hold the power button and choose the Aurora volume you staged it on."
          + unchanged
      case .otherMac:
        return "The staged upgrade was planned for another Mac." + unchanged
      case .otherPartition:
        return
          "The EFI partition the upgrade was staged with isn't on this Mac's disk any more."
          + unchanged
      case .requestDiffers:
        return
          "The upgrade request on the EFI partition doesn't match the one on this volume. Run aurora-upgrade cancel in Linux, then stage it again."
          + unchanged
      case .noStubInfo:
        return
          "asahi/stub_info.json on the EFI partition doesn't name this startup volume, so Aurora can't tell which installation this is."
          + unchanged
      case .firmwareFloor(let have, let need):
        return
          "This Mac's system firmware (\(have)) is older than the new startup firmware needs (\(need)). Update macOS first."
          + unchanged
      case .stage1Changed:
        return "The staged Stage 1 doesn't match the upgrade request." + unchanged
      case .versionMetadata:
        return
          "This volume's macOS version file is missing or present twice; the upgrade expects the state aurora-upgrade left."
          + unchanged
      case .imageDiffers:
        return
          "Apple's server returned a different restore image than the one this upgrade is pinned to."
          + unchanged
      case .space(let need, let free):
        return
          "The startup container has \(free / 1_000_000) MB free; the upgrade needs \(need / 1_000_000) MB."
          + unchanged
      case .partitionFull:
        return "The EFI partition has less than 100 MB free." + unchanged
      }
    }
  }

  /// The installer's Recovery working room beside the restored stub
  /// (NativeEnrollmentSpace), as aurora-upgrade's `Space.peak` counts it.
  public static let recoveryRoom: UInt64 = 512 << 20
  public static let espFloor: UInt64 = 100 << 20

  /// Everything that needs no network. Returns the request.
  public static func verify(config: Data, facts: StubUpgradeFacts) throws -> StubUpgradeRequest {
    guard facts.launchedByMarker else { throw Refusal.notLaunched }
    let request: StubUpgradeRequest
    do { request = try StubUpgradeRequest.decode(config) } catch { throw Refusal.notStaged }
    guard request.group == facts.group.uppercased() else { throw Refusal.otherVolume }
    guard facts.chipID == request.chipID, facts.deviceClass == request.deviceClass else {
      throw Refusal.otherMac
    }
    guard facts.espPartitionUUID?.lowercased() == request.espPartitionUUID else {
      throw Refusal.otherPartition
    }
    // aurora-upgrade writes both from one json.dumps: the same bytes.
    guard facts.espRequest == config else { throw Refusal.requestDiffers }
    guard let info = facts.stubInfo,
      let object = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
      (object["vgid"] as? String).flatMap(UUID.init(uuidString:))?.uuidString == request.group
    else { throw Refusal.noStubInfo }
    guard let firmware = facts.systemFirmware,
      (try? versionAtLeast(firmware, request.target.minimumBoot)) == true
    else {
      throw Refusal.firmwareFloor(
        have: facts.systemFirmware ?? "unknown", need: request.target.minimumBoot)
    }
    guard let stage1 = facts.stage1, RecoveryDigest.sha256(stage1) == request.stage1SHA256 else {
      throw Refusal.stage1Changed
    }
    guard facts.systemVersionVisible != facts.systemVersionHidden else {
      throw Refusal.versionMetadata
    }
    guard facts.espFreeBytes >= espFloor else { throw Refusal.partitionFull }
    return request
  }

  /// What the swap still needs at most beyond what the container holds now,
  /// for a run that has reached `phase`: the new restore bundle beside the
  /// old one, the new Recovery image once the old one is removed, and the
  /// installer's Recovery room. aurora-upgrade's peak, measured from here.
  public static func neededBytes(
    plan: RestoreImageStubPlan, facts: StubUpgradeFacts, phase: RestoreImageStubUpgrade.Phase?
  ) -> UInt64 {
    let preboot = plan.copies.filter { $0.role == "Preboot" }.reduce(UInt64(plan.manifest.count)) {
      $0 + UInt64(plan.entries[$1.member]?.size ?? 0)
    }
    let reached = phase ?? .started
    var need = recoveryRoom
    if reached < .prebootWritten { need += preboot }
    if reached < .recoveryWritten {
      need += UInt64(plan.recoveryMember.size)
      if facts.recoveryImageReleasable {
        need -= min(need, facts.recoveryImageBytes)
      }
    }
    return need
  }

  /// The checks on Apple's image (its plan is built against the pin) and the space.
  public static func verify(
    plan: RestoreImageStubPlan, facts: StubUpgradeFacts, phase: RestoreImageStubUpgrade.Phase?
  ) throws {
    let need = neededBytes(plan: plan, facts: facts, phase: phase)
    guard need <= facts.containerFreeBytes else {
      throw Refusal.space(need: need, free: facts.containerFreeBytes)
    }
  }

  /// The installer's NativeInspectionPolicy.Version rule, as aurora-upgrade
  /// ports it: parts split at "-", ",", "." and " ", numbers compared as
  /// numbers, "N beta M" before N.
  public static func versionAtLeast(_ lhs: String, _ rhs: String) throws -> Bool {
    enum Part: Equatable {
      case number(Int)
      case text(String)
    }
    func parts(_ value: String) throws -> [Part] {
      guard !value.isEmpty, value.utf8.count <= 128 else { throw Refusal.notStaged }
      var out = value.split(
        omittingEmptySubsequences: false, whereSeparator: { "-,. ".contains($0) }
      ).map { piece -> Part in
        let text = String(piece)
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
          let number = Int(text)
        {
          return .number(number)
        }
        return .text(text)
      }
      if out.count > 3, out[out.count - 2] == .text("beta") {
        guard case .number(let base) = out[out.count - 3] else { throw Refusal.notStaged }
        out[out.count - 3] = .number(base - 1)
        out[out.count - 2] = .number(99)
      }
      return out
    }
    let left = try parts(lhs)
    let right = try parts(rhs)
    for (a, b) in zip(left, right) where a != b {
      switch (a, b) {
      case (.number(let x), .number(let y)): return x > y
      case (.text(let x), .text(let y)):
        return Array(x.unicodeScalars.map(\.value)).lexicographicallyPrecedes(
          y.unicodeScalars.map(\.value)) == false
      default: throw Refusal.notStaged
      }
    }
    return left.count >= right.count
  }
}

extension StubUpgradeCheck {
  /// The restore image's plan for this Mac, built against the request's pin
  /// (image size, BuildManifest.plist SHA-256 and build); Apple serving
  /// anything else is `imageDiffers`.
  public static func plan(
    _ request: StubUpgradeRequest, directory: RestoreImageDirectory,
    read: RestoreImageDirectory.Read, boardID: UInt64
  ) throws -> RestoreImageStubPlan {
    do {
      return try RestoreImageStubPlan(
        directory: directory, read: read, productVersion: request.target.version,
        deviceClass: request.deviceClass, boardID: boardID, chipID: request.chipID,
        pin: .init(
          sourceBytes: request.target.sourceBytes,
          manifestSHA256: request.target.manifestSHA256, build: request.target.build),
        sha256: RecoveryDigest.sha256)
    } catch RestoreImageStubPlan.Failure.pinMismatch {
      throw Refusal.imageDiffers
    }
  }
}
