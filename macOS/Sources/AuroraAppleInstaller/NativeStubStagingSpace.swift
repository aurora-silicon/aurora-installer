#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import RecoveryAccountCore

  /// macOS lacks the free space an installation step needs there. Both
  /// numbers are bytes on the macOS volume that holds the installer's files,
  /// as `statfs` reports them to the helper.
  public struct MacOSFreeSpaceShortfall: Error, Equatable, Sendable {
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(requiredBytes: UInt64, availableBytes: UInt64) {
      self.requiredBytes = requiredBytes
      self.availableBytes = availableBytes
    }

    static let summaryPrefix = "macOS needs "

    /// One printable-ASCII sentence, well under the notice limit. The
    /// requirement rounds up and the free space rounds down, each to a tenth
    /// of a gigabyte, and the amount to free is their difference: the shown
    /// figures add up, and freeing that much is always enough.
    public var summary: String {
      let required = Self.tenths(requiredBytes, roundingUp: true)
      let available = Self.tenths(availableBytes, roundingUp: false)
      let missing = max(required - min(required, available), 1)
      return "\(Self.summaryPrefix)\(Self.gigabytes(required)) free to prepare the installation "
        + "and has \(Self.gigabytes(available)). Free up \(Self.gigabytes(missing)), "
        + "then try again."
    }

    /// Whether a notice summary has the shape `summary` produces.
    public static func isSummary(_ text: String) -> Bool {
      text.hasPrefix(summaryPrefix) && text.contains(" free to prepare the installation and has ")
        && text.hasSuffix(", then try again.")
    }

    private static func tenths(_ bytes: UInt64, roundingUp: Bool) -> UInt64 {
      let unit: UInt64 = 100_000_000
      return bytes / unit + (roundingUp && bytes % unit != 0 ? 1 : 0)
    }

    private static func gigabytes(_ tenths: UInt64) -> String {
      "\(tenths / 10).\(tenths % 10) GB"
    }
  }

  /// The free space the restore stub stage needs on macOS, mirroring the
  /// stage's own checks: the cache floor, everything it caches and its
  /// largest range, and for an encrypted member the decode check plus the
  /// decoder's two copies. See docs/native-stub-files.md.
  struct NativeStubStagingRequirement: Equatable, Sendable {
    static let floorBytes = NativeStubRestoreCache.reserveBytes
    static let decodeHeadroomBytes: UInt64 = 8 << 30
    /// The largest single range the cache fetches.
    static let largestRangeBytes: UInt64 = 8 << 20
    /// The ZIP directory's own cap and the end-of-directory read.
    static let directoryBytes: UInt64 = (8 << 20) + 65_557
    /// A deflated member's prefix read is kept apart from its body ranges.
    static let prefixBytes: UInt64 = 65_536
    /// A local record's fixed header, its longest name and its longest extra
    /// field: the record's small reads never reach past this.
    static let recordBytes = 30 + 4096 + 65_535

    /// One member the stage reads from the archive, as its directory
    /// describes it.
    struct Read: Equatable, Sendable {
      let name: String
      let recordOffset: Int
      let compressedSize: Int

      init(name: String, recordOffset: Int, compressedSize: Int) {
        self.name = name
        self.recordOffset = recordOffset
        self.compressedSize = compressedSize
      }

      init(_ member: IPSWArchiveMember) {
        self.init(
          name: member.name, recordOffset: member.localHeaderOffset,
          compressedSize: member.compressedSize)
      }
    }

    /// Bytes the restore-image cache adds for the stage's reads.
    let cacheBytes: UInt64
    /// The largest member the stage decodes on macOS, or zero.
    let largestDecodeBytes: UInt64

    var requiredFreeBytes: UInt64 {
      let fetching = fetchingFreeBytes
      guard largestDecodeBytes > 0 else { return fetching }
      return max(
        fetching,
        Self.decodeFreeBytes(memberBytes: largestDecodeBytes) + cacheBytes
          + largestDecodeBytes)
    }

    /// The same requirement once `cachedBytes` of the stage's reads are kept.
    func remaining(cachedBytes: UInt64) -> Self {
      Self(
        cacheBytes: cacheBytes - min(cacheBytes, cachedBytes),
        largestDecodeBytes: largestDecodeBytes)
    }

    /// What fetching the rest needs, without any decode.
    var fetchingFreeBytes: UInt64 { Self.floorBytes + cacheBytes + Self.largestRangeBytes }

    /// The archive spans the stage reads for these members: each local
    /// record and its body.
    static func spans(_ members: [IPSWArchiveMember]) -> [Range<Int>] {
      members.map {
        $0.localHeaderOffset..<($0.localHeaderOffset + recordBytes + $0.compressedSize)
      }
    }

    /// The free space a decode needs once its member is staged.
    static func decodeFreeBytes(memberBytes: UInt64) -> UInt64 {
      floorBytes + memberBytes + decodeHeadroomBytes
    }

    init(cacheBytes: UInt64, largestDecodeBytes: UInt64) {
      self.cacheBytes = cacheBytes
      self.largestDecodeBytes = largestDecodeBytes
    }

    /// The requirement for a stub plan. `decoded` are the restored members
    /// that are Apple Encrypted Archives. A requirement made before anything
    /// was cached also counts the reads that build the plan.
    init(
      plan: NativeStubFilePlan, decoded: [IPSWArchiveMember], includingPlanningReads: Bool
    ) {
      var members = plan.readMembers
      var extra: UInt64 = 0
      if includingPlanningReads {
        let planning = Set(
          ["BuildManifest.plist", "usr/standalone/bootcaches.plist", "SystemVersion.plist"].map(
            plan.layout.member))
        members += plan.archive.members.filter { planning.contains($0.name) }
        extra = Self.directoryBytes
      }
      self.init(
        cacheBytes: Self.cacheBytes(reading: members.map(Read.init)) + extra,
        largestDecodeBytes: decoded.map { UInt64($0.sizeBytes) }.max() ?? 0)
    }

    /// What the cache keeps for these members: each body as read, a prefix
    /// read, and every one-megabyte window that the record and the body's
    /// last short range can touch, counted once however many members share
    /// it.
    static func cacheBytes(reading members: [Read]) -> UInt64 {
      let window = NativeStubRestoreCache.windowBytes
      var windows = Set<Int>()
      var total: UInt64 = 0
      var seen = Set<String>()
      for member in members where seen.insert(member.name).inserted {
        total += UInt64(member.compressedSize) + prefixBytes
        let record = member.recordOffset
        windows.formUnion((record / window)...((record + recordBytes) / window))
        // The body starts inside the record's reach, so its final range
        // (or the whole body, when it is short) ends within this span.
        let earliestEnd = record + 30 + member.compressedSize
        let latestEnd = record + recordBytes + member.compressedSize
        let tail = max(record, earliestEnd - 65_536)
        windows.formUnion((tail / window)...(latestEnd / window))
      }
      return total + UInt64(windows.count) * UInt64(window)
    }

    /// The restored members that are Apple Encrypted Archives, told apart
    /// by the same prefix `NativeStubFilesExecution` reads before decoding.
    static func decodedMembers(of plan: NativeStubFilePlan) async throws -> [IPSWArchiveMember] {
      try await withThrowingTaskGroup(of: IPSWArchiveMember?.self) { group in
        var decoded = [IPSWArchiveMember]()
        for (index, member) in plan.restoredMembers.enumerated() {
          if index >= 8, let next = try await group.next(), let next { decoded.append(next) }
          group.addTask {
            try await plan.archive.readPrefix(member, maximumBytes: 4) == Data("AEA1".utf8)
              ? member : nil
          }
        }
        for try await member in group { if let member { decoded.append(member) } }
        return decoded.sorted { $0.name < $1.name }
      }
    }

    /// The whole stage's requirement, worked out from the restore image
    /// itself without writing anything: the planning reads stay in memory.
    static func estimate(
      source: any FirmwareRangeReading, firmware: NativeFirmwareSelection, deviceIdentifier: String,
      boardID: UInt64, chipID: UInt64
    ) async throws -> Self {
      let archive = try await IPSWArchive.open(NativeWindowedRangeReader(source))
      let plan = try await NativeStubFilePlan(
        archive: archive, source: firmware,
        deviceClass: String(deviceIdentifier.dropFirst(6)) + "ap",
        boardID: boardID, chipID: chipID, admitRecords: false)
      return Self(
        plan: plan, decoded: try await decodedMembers(of: plan), includingPlanningReads: true)
    }
  }

  /// A restore image read for planning only. Reads shorter than 64 KiB share
  /// one-megabyte windows held in memory, as the helper's cache holds them
  /// on disk, so a plan's local records cost a few requests. Longer reads go
  /// straight to the source and are not kept.
  actor NativeWindowedRangeReader: FirmwareRangeReading {
    static let maximumWindows = 128
    nonisolated let sizeBytes: Int
    private let source: any FirmwareRangeReading
    private var windows = [Int: Data]()
    private var pending = [Int: Task<Data, Error>]()

    init(_ source: any FirmwareRangeReading) {
      self.source = source
      sizeBytes = source.sizeBytes
    }

    func read(offset: Int, count: Int) async throws -> Data {
      try Task.checkCancellation()
      guard offset >= 0, count > 0, offset <= sizeBytes - count else {
        throw NativeStubFileError.invalidPlan
      }
      if count >= 65_536 { return try await source.read(offset: offset, count: count) }
      let size = NativeStubRestoreCache.windowBytes
      var bytes = Data()
      var cursor = offset
      while cursor < offset + count {
        let index = cursor / size
        let window = try await self.window(index, size: size)
        let end = min(index * size + window.count, offset + count)
        guard end > cursor else { throw NativeStubFileError.invalidPlan }
        bytes.append(window.subdata(in: (cursor - index * size)..<(end - index * size)))
        cursor = end
      }
      return bytes
    }

    private func window(_ index: Int, size: Int) async throws -> Data {
      if let kept = windows[index] { return kept }
      if let task = pending[index] { return try await task.value }
      let start = index * size
      let source = self.source
      let task = Task { try await source.read(offset: start, count: min(size, sizeBytes - start)) }
      pending[index] = task
      defer { pending.removeValue(forKey: index) }
      let bytes = try await task.value
      if windows.count >= Self.maximumWindows, let any = windows.keys.first {
        windows.removeValue(forKey: any)
      }
      windows[index] = bytes
      return bytes
    }
  }

  /// The macOS volume the helper stages files on, as an unprivileged app can
  /// measure it: the helper's own directory is private, so `statfs` names
  /// it, or its parent before the helper first runs.
  public enum MacOSStagingVolume {
    public static func freeBytes(
      directory: URL = URL(fileURLWithPath: InstallerProductIdentity.helperWorkingDirectory)
    ) throws -> UInt64 {
      for candidate in [directory, directory.deletingLastPathComponent()] {
        if let free = NativeStubRestoreCache.freeBytes(candidate) { return free }
      }
      throw NativeStubFileError.freeSpaceUnavailable
    }
  }

  /// What a fresh installation stages on macOS, worked out while the plan is
  /// prepared, before the person approves anything.
  public struct NativeStubStagingEstimator: Sendable {
    /// The helper's own files before the stub stage, such as the Recovery
    /// template (at most 128 MiB) and firmware ranges, and
    /// ordinary macOS writes between planning and staging.
    public static let planningMarginBytes: UInt64 = 1 << 30

    private let facts: @Sendable () throws -> NativeFirmwareSelection.Facts
    private let boardID: @Sendable () throws -> UInt64
    private let open: @Sendable (URL) async throws -> any FirmwareRangeReading

    public init() {
      facts = { try .live() }
      boardID = { try NativeStubFilePlatform.live.boardID() }
      open = { try await IPSWHTTPRangeReader.discover(url: $0) }
    }

    init(
      facts: @escaping @Sendable () throws -> NativeFirmwareSelection.Facts,
      boardID: @escaping @Sendable () throws -> UInt64,
      open: @escaping @Sendable (URL) async throws -> any FirmwareRangeReading
    ) {
      self.facts = facts
      self.boardID = boardID
      self.open = open
    }

    /// Refuses a Mac whose signed metadata says this release can't
    /// start it. It needs only this Mac's facts, the metadata and the firmware
    /// choice, so it runs before the payload and the restore image download.
    /// A firmware that can't be chosen is reported by the stub estimate instead.
    public func refuseUnstartableMachO(deviceIdentifier: String, metadata: StagedInstallerArtifact)
      throws
    {
      let facts = try facts()
      let data = try NativeInstallationMetadata.authenticatedData(metadata)
      guard
        let firmware = try? NativeFirmwareSelection.choose(
          deviceIdentifier: deviceIdentifier, facts: facts,
          metadata: NativeInstallationMetadata(data: data),
          policy: NativeInspectionPolicy.sealed())
      else { return }
      if try NativeBootChain.machORefusal(
        metadata: data, deviceIdentifier: deviceIdentifier,
        firmware: firmware.version.components(separatedBy: " ")[0],
        executeWindow: AuraStage1Format.usesExecuteWindow(chipID: facts.hardware.chipID)) != nil
      {
        throw InstallerPlanPreparationError.releaseLacksMachOStartup
      }
    }

    /// The free bytes macOS needs for the stub stage, counted from this
    /// Mac's own restore plan with nothing cached yet, plus the margin.
    public func requiredFreeBytes(deviceIdentifier: String, metadata: StagedInstallerArtifact)
      async throws -> UInt64
    {
      let facts = try facts()
      let firmware: NativeFirmwareSelection
      do {
        firmware = try NativeFirmwareSelection.choose(
          deviceIdentifier: deviceIdentifier, facts: facts,
          metadata: NativeInstallationMetadata.authenticated(metadata),
          policy: NativeInspectionPolicy.sealed())
      } catch NativeFirmwareSelectionError.macOSUpdateRequired(let version) {
        throw InstallerPlanPreparationError.macOSUpdateRequired(version: version)
      } catch NativeFirmwareSelectionError.unsupportedDevice {
        throw InstallerPlanPreparationError.unsupportedDevice(deviceIdentifier)
      } catch is NativeFirmwareSelectionError {
        throw InstallerPlanPreparationError.firmwareUnavailable
      }
      guard NativeRestoreSourceLayout(sourceURL: firmware.sourceURL) != nil else {
        throw InstallerPlanPreparationError.firmwareUnavailable
      }
      let requirement: NativeStubStagingRequirement
      do {
        requirement = try await NativeStubStagingRequirement.estimate(
          source: open(firmware.sourceURL), firmware: firmware,
          deviceIdentifier: deviceIdentifier, boardID: boardID(), chipID: facts.hardware.chipID)
      } catch NativeFirmwareSelectionError.updateArchiveOnly(let version) {
        // An update archive whose Recovery image patches an earlier one.
        throw InstallerPlanPreparationError.firmwareArchiveUnsupported(version: version)
      }
      return requirement.requiredFreeBytes + Self.planningMarginBytes
    }
  }

  /// Planning keeps the free space macOS needs for what the installation
  /// stages there: the payload download still to come and the stub stage.
  /// The helper's clones of the downloads share their blocks on APFS, so
  /// only their full-copy fallback, which the resize reserve already
  /// withholds, would need more.
  public enum MacOSStagingAdmission {
    public static func admit(
      _ recommendation: InstallerAllocationRecommendation, macOSStoreIdentifier: String,
      macOSFreeBytes: UInt64, outstandingDownloadBytes: UInt64, stagingBytes: UInt64
    ) throws -> InstallerAllocationRecommendation {
      let (needed, overflow) = outstandingDownloadBytes.addingReportingOverflow(stagingBytes)
      guard !overflow else {
        throw MacOSFreeSpaceShortfall(requiredBytes: .max, availableBytes: macOSFreeBytes)
      }
      let candidate = recommendation.candidate
      guard candidate.kind == "resize", candidate.sourceIdentifier == macOSStoreIdentifier else {
        guard ["free", "resize", "replace"].contains(candidate.kind), macOSFreeBytes < needed else {
          return recommendation
        }
        throw MacOSFreeSpaceShortfall(requiredBytes: needed, availableBytes: macOSFreeBytes)
      }
      // Shrinking macOS hands Aurora free space macOS had, before the stub
      // stage runs: the largest size must still leave macOS what it needs.
      let ceiling = macOSFreeBytes > needed ? macOSFreeBytes - needed : 0
      guard let limited = recommendation.limited(toMaximumBytes: ceiling) else {
        let (required, overflow) = needed.addingReportingOverflow(recommendation.floorBytes)
        throw MacOSFreeSpaceShortfall(
          requiredBytes: overflow ? .max : required, availableBytes: macOSFreeBytes)
      }
      return limited
    }
  }
#endif
