#if os(macOS)
  import Foundation

  /// Moving an existing installation to newer startup firmware without
  /// touching Linux.
  ///
  /// The startup firmware is the stub macOS that iBoot starts for Linux: its
  /// Preboot holds the GPU, DCP, AOP, ANE, AVE, ISP, PMP, SIO and SEP
  /// firmware iBoot loads. It changes only with a new stub. A slot is a
  /// second startup container, built from the pinned restore image beside the
  /// installation's own. Its Stage 1 names the installation's EFI partition,
  /// so both containers start the same Stage 2, kernel and root file system,
  /// and the Mac can go back to the old firmware from the startup options
  /// until the slot is made permanent.
  ///
  /// A pre-macOS 26 stub container is 2.5 GB and the EFI partition follows it,
  /// so a 26.0 or later stub (6 GB) can't replace it in place on M1 to M3
  /// Macs: a slot is the only way that keeps Linux.
  enum NativeStartupFirmwareSlot {
    /// The installation as recognition and its EFI partition record it.
    struct Installation: Equatable, Sendable {
      /// The installation's System volume name, as recognition admitted it.
      let title: String
      let espUUID: String
      /// The startup container's whole size.
      let stubBytes: UInt64
      /// Where the installation's Root partition ends.
      let endOffset: UInt64
      /// `asahi/stub_info.json` on the EFI partition: the build the current
      /// vendor firmware came from. Nil when the file is missing or unreadable.
      let build: String?
      let version: String?

      /// Reads the `manifest_info.build_number` and `system_version` fields
      /// an installer wrote to `asahi/stub_info.json`.
      static func stubInfo(_ data: Data?) -> (build: String?, version: String?) {
        guard let data, data.count <= 1 << 20,
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let manifest = info["manifest_info"] as? [String: Any]
        let system = info["system_version"] as? [String: Any]
        let build = (manifest?["build_number"] as? String).flatMap(validBuild)
        let version = system?["ProductVersion"] as? String
        return (build, version.flatMap { $0.isEmpty || $0.utf8.count > 32 ? nil : $0 })
      }
    }

    /// A slot that already exists for this installation.
    struct Slot: Equatable, Sendable {
      let title: String
      let build: String
      let storeIdentifier: String
    }

    struct Extent: Equatable, Sendable {
      let offset: UInt64
      let size: UInt64
    }

    struct Space: Equatable, Sendable {
      /// Unallocated extents on the installation's disk.
      let free: [Extent]
      /// How far macOS's container may shrink, after the installer's own
      /// floors. Zero when macOS can't be resized.
      let macOSShrinkableBytes: UInt64
    }

    enum Placement: Equatable, Sendable {
      /// The slot takes the start of this free extent.
      case free(Extent)
      /// macOS's container shrinks by this much and the slot takes the space.
      case shrinkMacOS(bytes: UInt64)
    }

    /// One step, in order, and who takes it.
    enum Step: Equatable, Sendable {
      case shrinkMacOS(bytes: UInt64)
      case createContainer(bytes: UInt64, title: String)
      case restoreStub(build: String, version: String)
      /// Recovery's inputs name the installation's EFI partition and the
      /// Stage 1 it enrolled.
      case stageRecovery(espUUID: String)
      /// The slot's own vendor firmware, beside the current one on the same
      /// EFI partition; the current files stay as they are.
      case writeSlotFirmware(directory: String)
      /// The owner, in the slot's Recovery from the startup options.
      case enrollInRecovery(title: String)

      var byOwner: Bool {
        if case .enrollInRecovery = self { return true }
        return false
      }
    }

    struct Plan: Equatable, Sendable {
      let build: String
      let version: String
      let title: String
      let bytes: UInt64
      let placement: Placement
      let firmwareDirectory: String
      let steps: [Step]
    }

    enum Decision: Equatable, Sendable {
      /// The installation already starts the pinned build.
      case current
      /// A slot with the pinned build exists; nothing needs to be created.
      case slotExists(Slot)
      case create(Plan)
    }

    enum Refusal: Error, Equatable, Sendable {
      /// Only a pinned build can be a slot: its version alone may name more
      /// than one firmware.
      case notPinned
      /// The current firmware's build can't be read, so the installer can't
      /// tell whether the move is an update.
      case unknownCurrentFirmware
      /// The selected firmware is older than the installation's.
      case olderFirmware(current: String, selected: String)
      /// A slot built from another image already exists; remove it first.
      case otherSlot(Slot)
      case notEnoughSpace(requiredBytes: UInt64, availableBytes: UInt64)

      var summary: String {
        func gigabytes(_ bytes: UInt64) -> String {
          String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        switch self {
        case .notPinned:
          return "This release names no exact startup firmware build for this Mac."
        case .unknownCurrentFirmware:
          return "The installation's EFI partition doesn't say which startup firmware it uses, so "
            + "it wasn't changed."
        case .olderFirmware(let current, let selected):
          return "This installation starts firmware \(current), newer than this release's "
            + "\(selected). Nothing was changed."
        case .otherSlot(let slot):
          return "\(slot.title) already holds startup firmware \(slot.build). Remove it before "
            + "adding another."
        case .notEnoughSpace(let required, let available):
          return "The new startup firmware needs \(gigabytes(required)) of disk space and "
            + "\(gigabytes(available)) can be made free. Free up space in macOS, then try again."
        }
      }
    }

    /// The slot's System volume name: the installation's, with the version.
    static func title(installation: String, version: String) -> String {
      installation + " " + version
    }

    /// Where the slot's vendor firmware goes on the shared EFI partition.
    /// Linux picks the set whose build matches the firmware it started on
    /// (`slots.json` in the same directory); the top-level set stays the
    /// fallback for a system that doesn't know slots yet.
    static func firmwareDirectory(build: String) -> String { "aurora/firmware/" + build }
    static let slotIndexPath = "aurora/firmware/slots.json"

    /// A policy version as the device tree spells it: three numbers.
    static func deviceTreeVersion(_ version: String) -> String? {
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      guard (1...3).contains(parts.count),
        parts.allSatisfy({
          !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && Int($0) != nil
        })
      else { return nil }
      return (parts.map(String.init) + Array(repeating: "0", count: 3 - parts.count))
        .joined(separator: ".")
    }

    static func validBuild(_ build: String) -> String? {
      guard !build.isEmpty, build.utf8.count <= 16,
        build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
      else { return nil }
      return build
    }

    static func decide(
      installation: Installation, slots: [Slot], target: NativeFirmwareSelection, space: Space
    ) throws -> Decision {
      guard let pin = target.pin, validBuild(pin.build) != nil else { throw Refusal.notPinned }
      guard let build = installation.build, let version = installation.version else {
        throw Refusal.unknownCurrentFirmware
      }
      if build == pin.build { return .current }
      guard try NativeInspectionPolicy.Version.atLeast(target.version, version) else {
        throw Refusal.olderFirmware(current: version, selected: target.version)
      }
      if let slot = slots.first {
        guard slots.count == 1, slot.build == pin.build else { throw Refusal.otherSlot(slot) }
        return .slotExists(slot)
      }
      let bytes = try NativeInspectionMath.alignUp(target.stubBytes)
      let placement = try place(bytes: bytes, after: installation.endOffset, space: space)
      let title = title(installation: installation.title, version: target.version)
      let directory = firmwareDirectory(build: pin.build)
      var steps = [Step]()
      if case .shrinkMacOS(let shrink) = placement { steps.append(.shrinkMacOS(bytes: shrink)) }
      steps += [
        .createContainer(bytes: bytes, title: title),
        .restoreStub(build: pin.build, version: target.version),
        .stageRecovery(espUUID: installation.espUUID),
        .writeSlotFirmware(directory: directory),
        .enrollInRecovery(title: title),
      ]
      return .create(
        Plan(
          build: pin.build, version: target.version, title: title, bytes: bytes,
          placement: placement, firmwareDirectory: directory, steps: steps))
    }

    /// The free extent right after the installation first, so its partitions
    /// stay together; then the smallest free extent that fits; then a macOS
    /// resize. Extents are used from their aligned start.
    static func place(bytes: UInt64, after end: UInt64, space: Space) throws -> Placement {
      var usable = [Extent]()
      for extent in space.free {
        let start = try NativeInspectionMath.alignUp(extent.offset)
        let (stop, overflow) = extent.offset.addingReportingOverflow(extent.size)
        guard !overflow, stop > start else { continue }
        let size = NativeInspectionMath.alignDown(stop - start)
        if size >= bytes { usable.append(Extent(offset: start, size: size)) }
      }
      if let adjacent = usable.first(where: {
        $0.offset >= end && $0.offset - end < NativeInspectionMath.unit
      }) {
        return .free(adjacent)
      }
      if let smallest = usable.min(by: { ($0.size, $0.offset) < ($1.size, $1.offset) }) {
        return .free(smallest)
      }
      if space.macOSShrinkableBytes >= bytes { return .shrinkMacOS(bytes: bytes) }
      let largest = space.free.map(\.size).max() ?? 0
      throw Refusal.notEnoughSpace(
        requiredBytes: bytes, availableBytes: max(largest, space.macOSShrinkableBytes))
    }

    /// `slots.json`: firmware version Linux reads from the device tree
    /// (`chosen/asahi,os-fw-version`) to the slot build whose files it loads.
    static func slotIndex(existing: Data?, version: String, build: String) throws -> Data {
      var index = [String: String]()
      if let existing {
        guard existing.count <= 65_536,
          let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
          object["schema"] as? Int == 1, let slots = object["slots"] as? [String: String]
        else { throw NativeStubFileError.changedFile }
        index = slots
      }
      guard validBuild(build) != nil, let key = deviceTreeVersion(version) else {
        throw NativeFirmwareSelectionError.invalidSource
      }
      index[key] = build
      return try JSONSerialization.data(
        withJSONObject: ["schema": 1, "slots": index],
        options: [.sortedKeys, .withoutEscapingSlashes])
    }
  }
#endif
