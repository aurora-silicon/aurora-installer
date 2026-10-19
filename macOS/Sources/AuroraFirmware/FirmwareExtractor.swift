// SPDX-License-Identifier: MIT
import Darwin
import Foundation

public struct FirmwareExtractionProgress: Equatable, Sendable {
  public enum Stage: String, Codable, Sendable {
    case downloading, authenticating, writing, complete
  }
  public let stage: Stage
  /// Verified range bytes, excluding retries and Apple's small FCS key response.
  public let completedBytes: Int
  public let totalBytes: Int
}

public struct FirmwareOutput: Codable, Equatable, Sendable {
  public let name: String
  public let sizeBytes: Int
  public let sha256: String
}

public struct FirmwareExtractionReceipt: Codable, Equatable, Sendable {
  public let deviceIdentifier: String
  public let sourceURL: URL
  public let recipeSHA256: String
  public let authenticatedRangeBytes: Int
  public let files: [FirmwareOutput]
}

/// A model/build-specific, sealed set of authenticated ranges. It does not claim
/// to verify the entire IPSW hash from a partial download.
public struct FirmwareExtractionPlan: Sendable {
  public let deviceIdentifier: String
  public let recipeSHA256: String
  let recipe: RangeRecipe

  public var sourceURL: URL { URL(string: recipe.source.url)! }
  public var sourceSizeBytes: Int { recipe.source.sizeBytes }
  public var authenticatedRangeBytes: Int {
    recipe.zipHeader.size + recipe.prefix.size
      + recipe.headers.reduce(0) { $0 + $1.size }
      + recipe.segments.values.reduce(0) { $0 + $1.size }
  }
  public var outputs: [FirmwareOutput] {
    recipe.files.map { FirmwareOutput(name: $0.name, sizeBytes: $0.size, sha256: $0.sha256) }
  }
  public var requiredDiskBytes: UInt64 {
    // Download/decode buffers stay in memory; publication renames this one tree.
    // Round each file to filesystem blocks and reserve metadata headroom.
    UInt64(recipe.files.reduce(1_048_576) { $0 + (($1.size + 4095) / 4096) * 4096 })
  }

  public static func bundled(for deviceIdentifier: String) throws -> Self {
    guard deviceIdentifier == "apple,j700",
      let path = Bundle.module.url(
        forResource: "j700-25G83-ranges", withExtension: "json", subdirectory: "Resources")
    else { throw RestoreFailure("No native firmware recipe is qualified for this Mac.") }
    let digest = "595d5acf3c4bca51c5749fc45691a7873f9216e2527436be9101757aae472834"
    return Self(
      deviceIdentifier: deviceIdentifier, recipeSHA256: digest,
      recipe: try readRecipe(path, digest: digest))
  }
}

/// Runs directly in the Swift installer process: Foundation range transport,
/// CryptoKit/CommonCrypto authentication and native Compression decoding.
/// It never starts Python, a shell, a decoder executable or a whole-IPSW fetch.
public struct FirmwareExtractor: Sendable {
  public init() {}

  public func extract(
    _ plan: FirmwareExtractionPlan, to output: URL,
    cacheDirectory: URL? = nil,
    progress: @escaping @Sendable (FirmwareExtractionProgress) -> Void = { _ in }
  ) async throws -> FirmwareExtractionReceipt {
    try require(
      output.isFileURL && !exists(output), "Firmware output must be a new local directory.")
    let parent = output.deletingLastPathComponent()
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
    let cacheBudget = cacheDirectory == nil ? 0 : UInt64(plan.authenticatedRangeBytes + 6 * segmentBytes)
    guard let free = attributes[.systemFreeSize] as? NSNumber,
      free.uint64Value >= plan.requiredDiskBytes + cacheBudget
    else { throw RestoreFailure("There is not enough free space to extract the firmware.") }
    progress(
      FirmwareExtractionProgress(
        stage: .downloading, completedBytes: 0, totalBytes: plan.authenticatedRangeBytes))
    let cache: FirmwareRangeCache?
    if let cacheDirectory {
      let path = cacheDirectory.standardizedFileURL.path
      let target = output.standardizedFileURL.path
      try require(path != target && !path.hasPrefix(target + "/"), "Checkpoint overlaps firmware output.")
      cache = try FirmwareRangeCache(directory: cacheDirectory, records: plan.recipe.rangeRecords)
    } else {
      cache = nil
    }
    try await extractFirmwareRecipe(plan.recipe, output: output, cache: cache, progress: progress)
    try await cache?.retire(plan.recipe.rangeRecords)
    return FirmwareExtractionReceipt(
      deviceIdentifier: plan.deviceIdentifier, sourceURL: plan.sourceURL,
      recipeSHA256: plan.recipeSHA256, authenticatedRangeBytes: plan.authenticatedRangeBytes,
      files: plan.outputs)
  }

  /// Reconcile a prior publication before reusing it after an interruption.
  /// Every admitted output must still be a regular file with its exact hash.
  public func verify(_ plan: FirmwareExtractionPlan, at output: URL) throws
    -> FirmwareExtractionReceipt
  {
    var info = stat()
    try require(
      output.isFileURL && lstat(output.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
      "The saved firmware directory is unsuitable.")
    for file in plan.outputs {
      var path = output
      for component in file.name.split(separator: "/") {
        path.appendPathComponent(String(component))
        try require(
          lstat(path.path, &info) == 0 && info.st_mode & S_IFMT != S_IFLNK,
          "The saved firmware path changed.")
      }
      let bytes = try readRegular(path, maximum: file.sizeBytes)
      try require(
        bytes.count == file.sizeBytes && bytes.sha256 == file.sha256,
        "The saved firmware does not match the admitted recipe.")
    }
    return FirmwareExtractionReceipt(
      deviceIdentifier: plan.deviceIdentifier, sourceURL: plan.sourceURL,
      recipeSHA256: plan.recipeSHA256, authenticatedRangeBytes: plan.authenticatedRangeBytes,
      files: plan.outputs)
  }
}
