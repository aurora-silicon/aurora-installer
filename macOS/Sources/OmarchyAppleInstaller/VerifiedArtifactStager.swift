import CryptoKit
import Darwin
import Foundation

public struct PinnedArtifactPart: Equatable, Sendable {
  public let sourceURL: URL
  public let fileName: String
  public let expectedDigest: String
  public let expectedSizeBytes: UInt64

  public init(
    sourceURL: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64
  ) throws {
    guard sourceURL.scheme == "https",
      sourceURL.host?.isEmpty == false,
      sourceURL.user == nil,
      sourceURL.password == nil,
      sourceURL.fragment == nil
    else {
      throw ArtifactStageError.invalidSourceURL
    }
    guard PinnedInstallerArtifact.isSafeFileName(fileName) else {
      throw ArtifactStageError.invalidFileName
    }
    guard SHA256Digest(rawValue: expectedDigest) != nil else {
      throw ArtifactStageError.invalidDigest
    }
    guard expectedSizeBytes > 0 else {
      throw ArtifactStageError.invalidExpectedSize
    }

    self.sourceURL = sourceURL
    self.fileName = fileName
    self.expectedDigest = expectedDigest
    self.expectedSizeBytes = expectedSizeBytes
  }
}

public struct PinnedInstallerArtifact: Equatable, Sendable {
  public static let maximumPartCount = 16

  public let role: String
  public let sourceURL: URL
  public let fileName: String
  public let expectedDigest: String
  public let expectedSizeBytes: UInt64
  public let parts: [PinnedArtifactPart]

  public init(
    role: String,
    sourceURL: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    parts: [PinnedArtifactPart] = []
  ) throws {
    guard !role.isEmpty, role.utf8.count <= 64 else {
      throw ArtifactStageError.invalidRole
    }
    guard sourceURL.scheme == "https",
      sourceURL.host?.isEmpty == false,
      sourceURL.user == nil,
      sourceURL.password == nil,
      sourceURL.fragment == nil
    else {
      throw ArtifactStageError.invalidSourceURL
    }
    guard Self.isSafeFileName(fileName) else {
      throw ArtifactStageError.invalidFileName
    }
    guard SHA256Digest(rawValue: expectedDigest) != nil else {
      throw ArtifactStageError.invalidDigest
    }
    guard expectedSizeBytes > 0 else {
      throw ArtifactStageError.invalidExpectedSize
    }
    if !parts.isEmpty {
      try Self.validate(
        parts: parts,
        wholeFileName: fileName,
        wholeSizeBytes: expectedSizeBytes
      )
    }

    self.role = role
    self.sourceURL = sourceURL
    self.fileName = fileName
    self.expectedDigest = expectedDigest
    self.expectedSizeBytes = expectedSizeBytes
    self.parts = parts
  }

  private static func validate(
    parts: [PinnedArtifactPart],
    wholeFileName: String,
    wholeSizeBytes: UInt64
  ) throws {
    guard (2...maximumPartCount).contains(parts.count) else {
      throw ArtifactStageError.invalidPartCount(parts.count)
    }

    var seenFileNames = Set<String>()
    var declaredBytes: UInt64 = 0
    for part in parts {
      guard part.fileName != wholeFileName else {
        throw ArtifactStageError.invalidPartFileName(part.fileName)
      }
      guard seenFileNames.insert(part.fileName).inserted else {
        throw ArtifactStageError.invalidPartFileName(part.fileName)
      }
      let sum = declaredBytes.addingReportingOverflow(part.expectedSizeBytes)
      guard !sum.overflow else {
        throw ArtifactStageError.partSizeSumMismatch(
          expected: wholeSizeBytes,
          actual: UInt64.max
        )
      }
      declaredBytes = sum.partialValue
    }
    guard declaredBytes == wholeSizeBytes else {
      throw ArtifactStageError.partSizeSumMismatch(
        expected: wholeSizeBytes,
        actual: declaredBytes
      )
    }
  }

  static func isSafeFileName(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && value.utf8.count <= 255
      && !value.utf8.contains(0)
      && !value.contains("/")
      && !value.contains("\\")
      && (value as NSString).lastPathComponent == value
  }

}

public struct StagedInstallerArtifact: Equatable, Sendable {
  public let artifact: PinnedInstallerArtifact
  public let fileURL: URL
  public let reusedExistingFile: Bool
  public let materialization: ArtifactMaterialization

  public init(
    artifact: PinnedInstallerArtifact,
    fileURL: URL,
    reusedExistingFile: Bool,
    materialization: ArtifactMaterialization? = nil
  ) {
    self.artifact = artifact
    self.fileURL = fileURL
    self.reusedExistingFile = reusedExistingFile
    self.materialization =
      materialization
      ?? (reusedExistingFile ? .reusedExistingFile : .atomicRename)
  }
}

public enum ArtifactMaterialization: String, Equatable, Sendable {
  case reusedExistingFile
  case atomicRename
  case verifiedCopyFallback
  case assembledFromParts
}

public struct ArtifactStagingProgress: Equatable, Sendable {
  public enum Phase: String, Equatable, Sendable {
    case downloading
    case assembling
    case verified
  }

  public let role: String
  public let fileName: String
  public let phase: Phase
  public let partIndex: Int?
  public let partCount: Int?
  public let bytesCompleted: UInt64
  public let totalBytes: UInt64

  public init(
    role: String,
    fileName: String,
    phase: Phase,
    partIndex: Int? = nil,
    partCount: Int? = nil,
    bytesCompleted: UInt64,
    totalBytes: UInt64
  ) {
    self.role = role
    self.fileName = fileName
    self.phase = phase
    self.partIndex = partIndex
    self.partCount = partCount
    self.bytesCompleted = bytesCompleted
    self.totalBytes = totalBytes
  }
}

public typealias ArtifactStagingProgressHandler =
  @Sendable (
    ArtifactStagingProgress
  ) -> Void

public enum ArtifactStageError: Error, Equatable, Sendable {
  case invalidRole
  case invalidSourceURL
  case invalidFileName
  case invalidDigest
  case invalidExpectedSize
  case invalidPartCount(Int)
  case invalidPartFileName(String)
  case partSizeSumMismatch(expected: UInt64, actual: UInt64)
  case unsafeStagingDirectory
  case unsafeStagedFile(String)
  case unexpectedHTTPStatus(Int)
  case sizeMismatch(expected: UInt64, actual: UInt64)
  case digestMismatch(expected: String, actual: String)
  case destinationConflict(String)
  case bundledArtifactMissing(String)
}

/// Stages pinned artifacts into a private directory, accepting bytes only when
/// the whole-file size and digest match the signed catalog.
///
/// Multi-part payloads download up to `partsInFlight` parts at a time, then are
/// streamed together into a single pending file whose SHA-256 is computed in
/// the same pass. Assembly therefore needs about twice the payload size on disk
/// until the parts are deleted. A verified part is kept until the payload is
/// assembled, and an interrupted part resumes from the bytes it already
/// received when the server allows it.
public struct VerifiedArtifactStager: Sendable {
  /// Each part is its own transfer, so several share a link that one
  /// connection can't fill.
  static let partsInFlight = 3

  /// Where an interrupted download keeps what its transfer needs to resume.
  static func resumeDataName(for fileName: String) -> String {
    fileName + ".resume"
  }

  /// Disk room required while a payload is assembled from parts (payload plus
  /// the pending concatenation) before the parts are deleted.
  public static func requiredFreeBytes(forPayloadSize size: UInt64) -> UInt64 {
    let (doubled, overflow) = size.multipliedReportingOverflow(by: 2)
    return overflow ? UInt64.max : doubled
  }

  /// Resume check: verified parts already occupy space, so only the remaining
  /// payload bytes plus assembly headroom are required — never 2× again.
  public static func requiredFreeBytes(
    forPayloadSize size: UInt64,
    alreadyOnDisk: UInt64
  ) -> UInt64 {
    let total = requiredFreeBytes(forPayloadSize: size)
    return total > alreadyOnDisk ? total - alreadyOnDisk : 0
  }

  private static let chunkBytes = 1_048_576

  private let downloader: any ArtifactDownloading
  private let promoter: AtomicArtifactFilePromoter
  private let bundledArtifactDirectory: URL?
  private let requiresBundledArtifacts: Bool

  public init() {
    downloader = ProgressReportingArtifactDownloader()
    promoter = AtomicArtifactFilePromoter()
    bundledArtifactDirectory = Bundle.main.resourceURL?.appendingPathComponent("Artifacts")
    requiresBundledArtifacts =
      Bundle.main.object(forInfoDictionaryKey: "OmarchyOfflineBundle") as? Bool == true
  }

  init(
    downloader: any ArtifactDownloading,
    promoter: AtomicArtifactFilePromoter = AtomicArtifactFilePromoter(),
    bundledArtifactDirectory: URL? = nil,
    requiresBundledArtifacts: Bool = false
  ) {
    self.downloader = downloader
    self.promoter = promoter
    self.bundledArtifactDirectory = bundledArtifactDirectory
    self.requiresBundledArtifacts = requiresBundledArtifacts
  }

  public func matches(_ artifact: PinnedInstallerArtifact, at fileURL: URL) -> Bool {
    (try? verify(artifact, at: fileURL)) != nil
  }

  public func requiresNetwork(for artifact: PinnedInstallerArtifact) -> Bool {
    !requiresBundledArtifacts && bundledSource(for: artifact) == nil
  }

  private func bundledSource(for artifact: PinnedInstallerArtifact) -> URL? {
    guard let source = bundledArtifactDirectory?.appendingPathComponent(artifact.fileName),
      FileManager.default.fileExists(atPath: source.path)
    else { return nil }
    return source
  }

  public func stage(
    _ artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    progress: ArtifactStagingProgressHandler? = nil
  ) async throws -> StagedInstallerArtifact {
    let fileManager = FileManager.default
    try ensureSafeDirectory(stagingDirectory, fileManager: fileManager)
    let destination = stagingDirectory.appendingPathComponent(
      artifact.fileName,
      isDirectory: false
    )

    if fileManager.fileExists(atPath: destination.path) {
      do {
        try verify(artifact, at: destination)
      } catch {
        throw ArtifactStageError.destinationConflict(artifact.fileName)
      }
      removeParts(of: artifact, in: stagingDirectory, fileManager: fileManager)
      report(
        progress,
        artifact: artifact,
        phase: .verified,
        bytesCompleted: artifact.expectedSizeBytes
      )
      return StagedInstallerArtifact(
        artifact: artifact,
        fileURL: destination,
        reusedExistingFile: true,
        materialization: .reusedExistingFile
      )
    }

    if let source = bundledSource(for: artifact) {
      // Every bundled artifact must match the authenticated catalog exactly.
      try verify(artifact, at: source)
      try Task.checkCancellation()
      let pending = stagingDirectory.appendingPathComponent(".pending-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: pending) }
      try fileManager.copyItem(at: source, to: pending)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
      try verify(artifact, at: pending)
      try Task.checkCancellation()
      try fileManager.moveItem(at: pending, to: destination)
      removeParts(of: artifact, in: stagingDirectory, fileManager: fileManager)
      report(
        progress, artifact: artifact, phase: .verified, bytesCompleted: artifact.expectedSizeBytes)
      return StagedInstallerArtifact(
        artifact: artifact, fileURL: destination, reusedExistingFile: false,
        materialization: .verifiedCopyFallback
      )
    }

    guard !requiresBundledArtifacts else {
      throw ArtifactStageError.bundledArtifactMissing(artifact.fileName)
    }

    guard !artifact.parts.isEmpty else {
      let onBytes = byteHandler(
        progress,
        artifact: artifact,
        partIndex: nil,
        partSizeBytes: artifact.expectedSizeBytes,
        completedBytes: 0
      )
      let staged = try await stageSingle(
        url: artifact.sourceURL,
        fileName: artifact.fileName,
        expectedDigest: artifact.expectedDigest,
        expectedSizeBytes: artifact.expectedSizeBytes,
        in: stagingDirectory,
        onBytes: onBytes
      )
      report(
        progress,
        artifact: artifact,
        phase: .verified,
        bytesCompleted: artifact.expectedSizeBytes
      )
      return StagedInstallerArtifact(
        artifact: artifact,
        fileURL: staged.fileURL,
        reusedExistingFile: staged.reused,
        materialization: staged.materialization
      )
    }

    return try await stageParts(
      artifact,
      in: stagingDirectory,
      destination: destination,
      progress: progress
    )
  }

  private func stageParts(
    _ artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    destination: URL,
    progress: ArtifactStagingProgressHandler?
  ) async throws -> StagedInstallerArtifact {
    let fileManager = FileManager.default
    let parts = artifact.parts
    let received = PartProgress(sizes: parts.map(\.expectedSizeBytes))
    var stagedParts = [URL?](repeating: nil, count: parts.count)
    // A part already in the staging folder must match before anything
    // downloads; a conflicting one fails closed.
    for (index, part) in parts.enumerated() {
      let existing = stagingDirectory.appendingPathComponent(part.fileName, isDirectory: false)
      guard fileManager.fileExists(atPath: existing.path) else { continue }
      do {
        try verify(
          fileName: part.fileName, expectedDigest: part.expectedDigest,
          expectedSizeBytes: part.expectedSizeBytes, at: existing)
      } catch {
        throw ArtifactStageError.destinationConflict(part.fileName)
      }
      stagedParts[index] = existing
      received.update(index, part.expectedSizeBytes) { completed in
        progress?(
          Self.progressEvent(
            artifact, phase: .downloading, partIndex: index, bytesCompleted: completed))
      }
    }
    let missing = parts.indices.filter { stagedParts[$0] == nil }
    // A failed part stops new parts from starting, but the ones in flight
    // finish, so a retry keeps every part that was verified.
    var failure: (any Error)?
    await withThrowingTaskGroup(of: (Int, URL).self) { group in
      var next = 0
      func start() {
        let index = missing[next]
        let part = parts[index]
        next += 1
        let onBytes: ArtifactByteProgressHandler? = progress.map { handler in
          let report: ArtifactByteProgressHandler = { bytes in
            received.update(index, bytes) { total in
              handler(
                Self.progressEvent(
                  artifact, phase: .downloading, partIndex: index, bytesCompleted: total))
            }
          }
          return report
        }
        group.addTask {
          let staged = try await self.stageSingle(
            url: part.sourceURL,
            fileName: part.fileName,
            expectedDigest: part.expectedDigest,
            expectedSizeBytes: part.expectedSizeBytes,
            in: stagingDirectory,
            onBytes: onBytes
          )
          return (index, staged.fileURL)
        }
      }
      while next < min(Self.partsInFlight, missing.count) { start() }
      while let result = await group.nextResult() {
        switch result {
        case .success(let (index, fileURL)):
          stagedParts[index] = fileURL
          received.update(index, parts[index].expectedSizeBytes) { completed in
            progress?(
              Self.progressEvent(
                artifact, phase: .downloading, partIndex: index, bytesCompleted: completed))
          }
          if failure == nil, next < missing.count { start() }
        case .failure(let error):
          if failure == nil { failure = error }
        }
      }
    }
    if let failure { throw failure }
    let partFileURLs = stagedParts.compactMap { $0 }
    guard partFileURLs.count == parts.count else { throw CancellationError() }
    let completedBytes = parts.reduce(UInt64(0)) { $0 + $1.expectedSizeBytes }

    report(
      progress,
      artifact: artifact,
      phase: .assembling,
      bytesCompleted: completedBytes
    )

    let pending = stagingDirectory.appendingPathComponent(
      ".pending-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: pending) }

    try assemble(
      parts: partFileURLs,
      into: pending,
      expectedDigest: artifact.expectedDigest,
      expectedSizeBytes: artifact.expectedSizeBytes
    )

    do {
      try fileManager.moveItem(at: pending, to: destination)
    } catch {
      guard fileManager.fileExists(atPath: destination.path) else {
        throw error
      }
      do {
        try verify(artifact, at: destination)
      } catch {
        throw ArtifactStageError.destinationConflict(artifact.fileName)
      }
    }

    for partFileURL in partFileURLs {
      try? fileManager.removeItem(at: partFileURL)
    }
    report(
      progress,
      artifact: artifact,
      phase: .verified,
      bytesCompleted: artifact.expectedSizeBytes
    )

    return StagedInstallerArtifact(
      artifact: artifact,
      fileURL: destination,
      reusedExistingFile: false,
      materialization: .assembledFromParts
    )
  }

  private func stageSingle(
    url: URL,
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    in stagingDirectory: URL,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> (
    fileURL: URL, materialization: ArtifactMaterialization, reused: Bool
  ) {
    let fileManager = FileManager.default
    let destination = stagingDirectory.appendingPathComponent(
      fileName,
      isDirectory: false
    )

    if fileManager.fileExists(atPath: destination.path) {
      do {
        try verify(
          fileName: fileName,
          expectedDigest: expectedDigest,
          expectedSizeBytes: expectedSizeBytes,
          at: destination
        )
      } catch {
        throw ArtifactStageError.destinationConflict(fileName)
      }
      return (destination, .reusedExistingFile, true)
    }

    let downloaded = try await downloader.download(
      from: url,
      expectedSizeBytes: expectedSizeBytes,
      resumeData: stagingDirectory.appendingPathComponent(
        Self.resumeDataName(for: fileName), isDirectory: false),
      onBytes: onBytes
    )
    defer { try? fileManager.removeItem(at: downloaded) }

    let pending = stagingDirectory.appendingPathComponent(
      ".pending-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: pending) }

    let materialization = try promoter.promote(
      source: downloaded,
      pending: pending
    )
    try verify(
      fileName: fileName,
      expectedDigest: expectedDigest,
      expectedSizeBytes: expectedSizeBytes,
      at: pending
    )

    do {
      try fileManager.moveItem(at: pending, to: destination)
    } catch {
      guard fileManager.fileExists(atPath: destination.path) else {
        throw error
      }
      do {
        try verify(
          fileName: fileName,
          expectedDigest: expectedDigest,
          expectedSizeBytes: expectedSizeBytes,
          at: destination
        )
      } catch {
        throw ArtifactStageError.destinationConflict(fileName)
      }
    }

    return (destination, materialization, false)
  }

  private func assemble(
    parts: [URL],
    into destination: URL,
    expectedDigest: String,
    expectedSizeBytes: UInt64
  ) throws {
    let fileManager = FileManager.default
    guard
      fileManager.createFile(
        atPath: destination.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw ArtifactStageError.unsafeStagedFile(destination.lastPathComponent)
    }

    let writer = try FileHandle(forWritingTo: destination)
    var hasher = SHA256()
    var size: UInt64 = 0

    do {
      for part in parts {
        let reader = try FileHandle(forReadingFrom: part)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: Self.chunkBytes),
          !chunk.isEmpty
        {
          try writer.write(contentsOf: chunk)
          hasher.update(data: chunk)
          let total = size.addingReportingOverflow(UInt64(chunk.count))
          guard !total.overflow else {
            throw ArtifactStageError.invalidExpectedSize
          }
          size = total.partialValue
        }
      }
      try writer.close()
    } catch {
      try? writer.close()
      throw error
    }

    guard size == expectedSizeBytes else {
      throw ArtifactStageError.sizeMismatch(
        expected: expectedSizeBytes,
        actual: size
      )
    }
    let digest = SHA256Digest.prefixedHex(hasher.finalize())
    guard digest == expectedDigest else {
      throw ArtifactStageError.digestMismatch(
        expected: expectedDigest,
        actual: digest
      )
    }
  }

  private func removeParts(
    of artifact: PinnedInstallerArtifact,
    in stagingDirectory: URL,
    fileManager: FileManager
  ) {
    for part in artifact.parts {
      try? fileManager.removeItem(
        at: stagingDirectory.appendingPathComponent(
          part.fileName,
          isDirectory: false
        )
      )
    }
  }

  private static func progressEvent(
    _ artifact: PinnedInstallerArtifact, phase: ArtifactStagingProgress.Phase, partIndex: Int?,
    bytesCompleted: UInt64
  ) -> ArtifactStagingProgress {
    ArtifactStagingProgress(
      role: artifact.role,
      fileName: artifact.fileName,
      phase: phase,
      partIndex: partIndex,
      partCount: artifact.parts.isEmpty ? nil : artifact.parts.count,
      bytesCompleted: bytesCompleted,
      totalBytes: artifact.expectedSizeBytes
    )
  }

  /// Bytes received by each part while several download at once. Totals are
  /// reported under the lock, so they never go backwards.
  private final class PartProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let sizes: [UInt64]
    private var received: [UInt64]

    init(sizes: [UInt64]) {
      self.sizes = sizes
      received = Array(repeating: 0, count: sizes.count)
    }

    func update(_ index: Int, _ bytes: UInt64, report: (UInt64) -> Void) {
      lock.withLock {
        received[index] = max(received[index], min(bytes, sizes[index]))
        report(received.reduce(0, +))
      }
    }
  }

  private func byteHandler(
    _ handler: ArtifactStagingProgressHandler?,
    artifact: PinnedInstallerArtifact,
    partIndex: Int?,
    partSizeBytes: UInt64,
    completedBytes: UInt64
  ) -> ArtifactByteProgressHandler? {
    guard let handler else {
      return nil
    }
    let role = artifact.role
    let fileName = artifact.fileName
    let partCount = artifact.parts.isEmpty ? nil : artifact.parts.count
    let totalBytes = artifact.expectedSizeBytes
    return { bytesReceived in
      handler(
        ArtifactStagingProgress(
          role: role,
          fileName: fileName,
          phase: .downloading,
          partIndex: partIndex,
          partCount: partCount,
          bytesCompleted: completedBytes + min(bytesReceived, partSizeBytes),
          totalBytes: totalBytes
        )
      )
    }
  }

  private func report(
    _ handler: ArtifactStagingProgressHandler?,
    artifact: PinnedInstallerArtifact,
    phase: ArtifactStagingProgress.Phase,
    partIndex: Int? = nil,
    bytesCompleted: UInt64
  ) {
    guard let handler else {
      return
    }
    handler(
      ArtifactStagingProgress(
        role: artifact.role,
        fileName: artifact.fileName,
        phase: phase,
        partIndex: partIndex,
        partCount: artifact.parts.isEmpty ? nil : artifact.parts.count,
        bytesCompleted: bytesCompleted,
        totalBytes: artifact.expectedSizeBytes
      )
    )
  }

  private func ensureSafeDirectory(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(
      atPath: directory.path,
      isDirectory: &isDirectory
    ) {
      let values = try directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard isDirectory.boolValue,
        values.isDirectory == true,
        values.isSymbolicLink != true
      else {
        throw ArtifactStageError.unsafeStagingDirectory
      }
      return
    }

    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let values = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ArtifactStageError.unsafeStagingDirectory
    }
  }

  private func verify(
    _ artifact: PinnedInstallerArtifact,
    at fileURL: URL
  ) throws {
    try verify(
      fileName: artifact.fileName,
      expectedDigest: artifact.expectedDigest,
      expectedSizeBytes: artifact.expectedSizeBytes,
      at: fileURL
    )
  }

  private func verify(
    fileName: String,
    expectedDigest: String,
    expectedSizeBytes: UInt64,
    at fileURL: URL
  ) throws {
    let values = try fileURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ArtifactStageError.unsafeStagedFile(fileName)
    }

    let result = try digestAndSize(of: fileURL)
    guard result.size == expectedSizeBytes else {
      throw ArtifactStageError.sizeMismatch(
        expected: expectedSizeBytes,
        actual: result.size
      )
    }
    guard result.digest == expectedDigest else {
      throw ArtifactStageError.digestMismatch(
        expected: expectedDigest,
        actual: result.digest
      )
    }
  }

  private func digestAndSize(
    of fileURL: URL
  ) throws -> (digest: String, size: UInt64) {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size: UInt64 = 0

    while let chunk = try handle.read(upToCount: Self.chunkBytes),
      !chunk.isEmpty
    {
      let addition = UInt64(chunk.count)
      guard !size.addingReportingOverflow(addition).overflow else {
        throw ArtifactStageError.invalidExpectedSize
      }
      size += addition
      hasher.update(data: chunk)
    }

    let digest = SHA256Digest.prefixedHex(hasher.finalize())
    return (digest, size)
  }
}

enum ArtifactRenameResult: Equatable, Sendable {
  case success
  case failure(Int32)
}

struct AtomicArtifactFilePromoter: Sendable {
  private let renameOperation: @Sendable (URL, URL) -> ArtifactRenameResult

  init() {
    renameOperation = { source, destination in
      let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
          Darwin.rename(sourcePath, destinationPath)
        }
      }
      return result == 0 ? .success : .failure(Darwin.errno)
    }
  }

  init(
    renameOperation: @escaping @Sendable (URL, URL) -> ArtifactRenameResult
  ) {
    self.renameOperation = renameOperation
  }

  func promote(
    source: URL,
    pending: URL
  ) throws -> ArtifactMaterialization {
    switch renameOperation(source, pending) {
    case .success:
      return .atomicRename
    case .failure(EXDEV):
      try FileManager.default.copyItem(at: source, to: pending)
      return .verifiedCopyFallback
    case .failure(let code):
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }
}

public typealias ArtifactByteProgressHandler =
  @Sendable (
    _ bytesReceived: UInt64
  ) -> Void

protocol ArtifactDownloading: Sendable {
  func download(from sourceURL: URL) async throws -> URL
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL
  /// Resumes from, and on interruption saves, what the transfer needs to
  /// continue at `resumeData`.
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    resumeData: URL,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL
}

extension ArtifactDownloading {
  /// Downloaders that can't resume start again from the first byte.
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    resumeData: URL,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try await download(from: sourceURL, expectedSizeBytes: expectedSizeBytes, onBytes: onBytes)
  }

  /// Bridges downloaders that only implement the unmetered form; the stager
  /// always calls the metered one.
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try await download(from: sourceURL)
  }
}

/// Downloads one artifact per call over an ephemeral session, reporting
/// throttled byte counts and cancelling any transfer that exceeds the pinned
/// size.
final class ProgressReportingArtifactDownloader: NSObject, ArtifactDownloading,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private static let reportIntervalSeconds: TimeInterval = 0.25
  private static let reportByteInterval: UInt64 = 16 * 1_048_576
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration
    super.init()
  }

  private struct Transfer {
    let continuation: CheckedContinuation<URL, any Error>
    let expectedSizeBytes: UInt64
    let onBytes: ArtifactByteProgressHandler?
    let resumeData: URL?
    var lastReportedBytes: UInt64 = 0
    var lastReportedAt: Date?
    var failure: (any Error)?
  }

  private let lock = NSLock()
  private var transfers = [ObjectIdentifier: Transfer]()

  func download(from sourceURL: URL) async throws -> URL {
    try await download(
      from: sourceURL,
      expectedSizeBytes: UInt64.max,
      onBytes: nil
    )
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try await transfer(
      sourceURL, resuming: nil, expectedSizeBytes: expectedSizeBytes, resumeData: nil,
      onBytes: onBytes)
  }

  /// An interrupted transfer leaves the system's resume data at `resumeData`.
  /// The next call continues from there, and starts again from the first byte
  /// only when the server refuses to continue, for example once a redirect's
  /// signed address has expired. A download that is interrupted again keeps
  /// its new resume data instead.
  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    resumeData: URL,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    if let saved = Self.takeResumeData(resumeData) {
      do {
        return try await transfer(
          sourceURL, resuming: saved, expectedSizeBytes: expectedSizeBytes,
          resumeData: resumeData, onBytes: onBytes)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if FileManager.default.fileExists(atPath: resumeData.path) { throw error }
      }
    }
    return try await transfer(
      sourceURL, resuming: nil, expectedSizeBytes: expectedSizeBytes, resumeData: resumeData,
      onBytes: onBytes)
  }

  private static func takeResumeData(_ url: URL) -> Data? {
    defer { try? FileManager.default.removeItem(at: url) }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_size > 0, info.st_size <= 1 << 20
    else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func saveResumeData(_ data: Data?, to url: URL?) {
    guard let data, !data.isEmpty, data.count <= 1 << 20, let url else { return }
    let pending = url.deletingLastPathComponent().appendingPathComponent(
      ".pending-resume-\(UUID().uuidString.lowercased())")
    guard
      FileManager.default.createFile(
        atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { return }
    if rename(pending.path, url.path) != 0 { try? FileManager.default.removeItem(at: pending) }
  }

  private func transfer(
    _ sourceURL: URL, resuming saved: Data?, expectedSizeBytes: UInt64, resumeData: URL?,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    try Task.checkCancellation()
    let session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }

    let task =
      saved.map { session.downloadTask(withResumeData: $0) }
      ?? session.downloadTask(with: sourceURL)
    let key = ObjectIdentifier(task)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        transfers[key] = Transfer(
          continuation: continuation,
          expectedSizeBytes: expectedSizeBytes,
          onBytes: onBytes,
          resumeData: resumeData
        )
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      // Pausing on a metered network or quitting keeps what arrived.
      if resumeData == nil {
        task.cancel()
      } else {
        task.cancel { Self.saveResumeData($0, to: resumeData) }
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let key = ObjectIdentifier(downloadTask)
    let received = UInt64(max(0, totalBytesWritten))
    var exceededPinnedSize = false
    var pendingReport: ArtifactByteProgressHandler?

    lock.lock()
    if var transfer = transfers[key] {
      if received > transfer.expectedSizeBytes {
        transfer.failure = ArtifactStageError.sizeMismatch(
          expected: transfer.expectedSizeBytes,
          actual: received
        )
        transfers[key] = transfer
        exceededPinnedSize = true
      } else {
        let now = Date()
        let elapsed =
          transfer.lastReportedAt.map { now.timeIntervalSince($0) }
          ?? Self.reportIntervalSeconds
        let delta =
          received >= transfer.lastReportedBytes
          ? received - transfer.lastReportedBytes : 0
        if elapsed >= Self.reportIntervalSeconds
          || delta >= Self.reportByteInterval
        {
          transfer.lastReportedAt = now
          transfer.lastReportedBytes = received
          transfers[key] = transfer
          pendingReport = transfer.onBytes
        }
      }
    }
    lock.unlock()

    guard !exceededPinnedSize else {
      downloadTask.cancel()
      return
    }
    pendingReport?(received)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let key = ObjectIdentifier(downloadTask)
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-download-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )

    var moveFailure: (any Error)?
    do {
      try fileManager.moveItem(at: location, to: temporaryURL)
    } catch {
      moveFailure = error
    }

    guard let response = downloadTask.response as? HTTPURLResponse,
      (200...299).contains(response.statusCode)
    else {
      try? fileManager.removeItem(at: temporaryURL)
      let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
      finish(key, with: .failure(ArtifactStageError.unexpectedHTTPStatus(status)))
      return
    }
    if let moveFailure {
      finish(key, with: .failure(moveFailure))
      return
    }
    finish(key, with: .success(temporaryURL))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let key = ObjectIdentifier(task)
    lock.lock()
    let recordedFailure = transfers[key]?.failure
    let resumeData = transfers[key]?.resumeData
    lock.unlock()
    if recordedFailure == nil, let error {
      Self.saveResumeData(
        (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, to: resumeData)
    }

    if let recordedFailure {
      finish(key, with: .failure(recordedFailure))
    } else if let error {
      let cancelled = (error as? URLError)?.code == .cancelled || Task.isCancelled
      finish(
        key,
        with: .failure(cancelled ? CancellationError() : error)
      )
    } else {
      finish(key, with: .failure(URLError(.badServerResponse)))
    }
  }

  private func finish(
    _ key: ObjectIdentifier,
    with result: Result<URL, any Error>
  ) {
    lock.lock()
    let transfer = transfers.removeValue(forKey: key)
    lock.unlock()

    guard let transfer else {
      if case .success(let fileURL) = result {
        try? FileManager.default.removeItem(at: fileURL)
      }
      return
    }
    transfer.continuation.resume(with: result)
  }
}
