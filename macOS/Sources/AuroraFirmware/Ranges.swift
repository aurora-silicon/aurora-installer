// SPDX-License-Identifier: MIT
import Darwin
import Foundation

struct DecodedSegment {
  let offset: Int
  let size: Int
  let plainSize: Int
  let hash: String
  let mac: Data
  let cluster: Int
  let index: Int
}
func decodeRanges(_ recipe: RangeRecipe, fetched: [RangeRecord: Data]) async throws -> [Int: Data] {
  guard let prefix = fetched[recipe.prefix] else { throw RestoreFailure("Missing AEA prefix.") }
  try require(
    try prefix.count >= 156 && prefix.part(0, 4) == Data("AEA1".utf8) && prefix.little(4, 4) == 1,
    "Unsupported AEA range profile.")
  let length = try prefix.little(8, 4)
  try require(
    length <= 1024 * 1024 && prefix.count == 12 + length + 32 + 112, "Invalid AEA prefix length.")
  let md = try metadata(prefix)
  guard let raw = md["com.apple.wkms.fcs-key-url"], let url = String(data: raw, encoding: .utf8)
  else {
    throw RestoreFailure("Missing FCS key URL.")
  }
  let key = try await unwrap(md, releaseKey: fetchKey(url))
  return try decodeRanges(recipe, fetched: fetched, archiveKey: key)
}
func decodeRanges(_ recipe: RangeRecipe, fetched: [RangeRecord: Data], archiveKey: Data) throws
  -> [Int: Data]
{
  guard let prefix = fetched[recipe.prefix] else { throw RestoreFailure("Missing AEA prefix.") }
  let length = try prefix.little(8, 4)
  let auth = try prefix.part(12, length)
  let salt = try prefix.part(12 + length, 32)
  let main = derive(
    archiveKey, salt: salt, info: try Data("AEA_AMK".utf8) + prefix.part(4, 4), size: 32)
  let root = try prefix.part(44 + length, 112)
  let rootMaterial = derive(main, info: Data("AEA_RHEK".utf8), size: 80)
  try authenticate(
    rootMaterial, data: root.part(32, 48), salt: root.part(80, 32) + auth,
    expected: root.part(0, 32))
  let rootPlain = try ctr(rootMaterial, data: root.part(32, 48))
  try require(
    try rootPlain.little(0, 8) == recipe.systemImage.decoded.sizeBytes
      && rootPlain.little(8, 8) == recipe.systemImage.sizeBytes
      && rootPlain.little(16, 4) == segmentBytes && rootPlain.little(20, 4) == clusterWidth
      && rootPlain[24] == UInt8(ascii: "e") && rootPlain[25] == 2,
    "AEA image parameters differ from recipe.")
  var descriptions: [Int: DecodedSegment] = [:]
  for header in recipe.headers {
    guard let data = fetched[header.record] else { throw RestoreFailure("Missing AEA cluster.") }
    let clusterKey = derive(main, info: indexedInfo("AEA_CK", header.cluster), size: 32)
    let material = derive(clusterKey, info: Data("AEA_CHEK".utf8), size: 80)
    let expected = try unhex(header.expectedMAC)
    if header.cluster == 0 {
      try require(
        try expected == root.part(80, 32) && header.offset == recipe.prefix.size,
        "AEA first cluster differs from root.")
    }
    let split = clusterWidth * 40
    try authenticate(
      material, data: data.part(0, split), salt: data.part(split, data.count - split),
      expected: expected)
    let plain = try ctr(material, data: data.part(0, split))
    var offset = header.offset + header.size
    for index in 0..<clusterWidth {
      let id = header.cluster * clusterWidth + index
      let entry = try plain.part(index * 40, 40)
      let plainSize = try entry.little(0, 4)
      let size = try entry.little(4, 4)
      let expectedSize = min(
        segmentBytes, max(0, recipe.systemImage.decoded.sizeBytes - id * segmentBytes))
      try require(
        plainSize == expectedSize && size <= plainSize && (plainSize == 0 || size > 0)
          && offset <= recipe.systemImage.sizeBytes - size, "Invalid AEA segment bounds.")
      if recipe.segments[String(id)] != nil {
        descriptions[id] = DecodedSegment(
          offset: offset, size: size, plainSize: plainSize,
          hash: try entry.part(8, 32).map { String(format: "%02x", $0) }.joined(),
          mac: try data.part(split + 32 + index * 32, 32), cluster: header.cluster, index: index)
      }
      offset += size
    }
  }
  var decoded: [Int: Data] = [:]
  for (key, record) in recipe.segments {
    try Task.checkCancellation()
    guard let id = Int(key), let description = descriptions[id],
      description.offset == record.offset, description.size == record.size,
      let data = fetched[record]
    else { throw RestoreFailure("AEA segment differs from recipe.") }
    let clusterKey = derive(main, info: indexedInfo("AEA_CK", description.cluster), size: 32)
    let material = derive(clusterKey, info: indexedInfo("AEA_SK", description.index), size: 80)
    try authenticate(material, data: data, expected: description.mac)
    var plain = try ctr(material, data: data)
    if description.size != description.plainSize {
      plain = try boundedLZFSE(plain, maximum: description.plainSize)
    }
    try require(
      plain.count == description.plainSize && plain.sha256 == description.hash,
      "AEA plaintext segment SHA-256 mismatch.")
    decoded[id] = plain
  }
  return decoded
}

func assembleRangeFiles(
  _ recipe: RangeRecipe, decoded: [Int: Data], output: URL, workspace: URL? = nil,
  preferred: [String: Data] = [:]
) throws {
  try require(!exists(output), "Firmware output already exists.")
  let fm = FileManager.default
  let work = try workspace ?? privateDirectory(beside: output, prefix: ".firmware-ranges-")
  defer { try? fm.removeItem(at: work) }
  for file in recipe.files {
    try Task.checkCancellation()
    var storage: [Data] = []
    for record in file.storage where preferred[file.name] == nil {
      var data = Data()
      for span in record.spans {
        var offset = span.offset
        var remaining = span.size
        while remaining > 0 {
          guard let segment = decoded[offset / segmentBytes], offset % segmentBytes < segment.count
          else {
            throw RestoreFailure("Missing plaintext dependency.")
          }
          let count = min(remaining, segment.count - offset % segmentBytes)
          data.append(try segment.part(offset % segmentBytes, count))
          offset += count
          remaining -= count
        }
      }
      try require(
        data.count == record.size && data.sha256 == record.sha256, "APFS storage SHA-256 mismatch.")
      storage.append(data)
    }
    var result =
      try preferred[file.name] ?? (file.compressed ? decompressStorage(storage) : storage[0])
    try require(result.sha256 == file.rawSHA256, "Source firmware SHA-256 mismatch.")
    if file.transform == "nvram" {
      try require(result.allSatisfy { $0 <= 127 }, "Non-ASCII NVRAM.")
      var normalized = ""
      for line in String(decoding: result, as: UTF8.self).components(separatedBy: "\n")
      where !line.isEmpty {
        guard let equal = line.firstIndex(of: "=") else {
          throw RestoreFailure("Invalid NVRAM record.")
        }
        normalized +=
          line[..<equal].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\u{b}\u{c}"))
          + "=" + line[line.index(after: equal)...] + "\n"
      }
      result = Data(normalized.utf8)
    }
    try require(
      result.count == file.size && result.sha256 == file.sha256, "Output firmware SHA-256 mismatch."
    )
    let target = work.appendingPathComponent(file.name)
    try fm.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try writePrivate(result, to: target)
  }
  try Task.checkCancellation()
  var directories: Set<URL> = [work]
  for file in recipe.files {
    var directory = work.appendingPathComponent(file.name).deletingLastPathComponent()
    while directory.path != work.path {
      directories.insert(directory)
      directory.deleteLastPathComponent()
    }
  }
  for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0, "Cannot open firmware output directory.")
    defer { close(fd) }
    try require(fsync(fd) == 0, "Cannot sync firmware output directory.")
  }
  // RENAME_EXCL makes the final publication atomic and refuses even an empty racing directory.
  try require(
    renamex_np(work.path, output.path, UInt32(RENAME_EXCL)) == 0,
    "Cannot publish firmware without replacing an existing output.")
  let parent = open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  try require(parent >= 0, "Cannot open firmware publication directory.")
  defer { close(parent) }
  try require(fsync(parent) == 0, "Cannot sync firmware publication directory.")
}

// Keep the sealed recipe's exact dependency closure for files still requiring IPSW data.
// Preferred bytes are admitted against the same output pins before any network access.
func networkRecipe(_ recipe: RangeRecipe, preferred: [String: Data]) throws -> RangeRecipe {
  try recipe.validate()
  for (name, bytes) in preferred {
    guard let file = recipe.files.first(where: { $0.name == name }),
      file.transform == "identity", bytes.count == file.size, bytes.sha256 == file.sha256
    else { throw RestoreFailure("Local firmware differs from the sealed recipe.") }
  }
  var network = recipe
  network.files.removeAll { preferred[$0.name] != nil }
  var ids = Set<Int>()
  for file in network.files {
    for storage in file.storage {
      for span in storage.spans {
        ids.formUnion((span.offset / segmentBytes)...((span.offset + span.size - 1) / segmentBytes))
      }
    }
  }
  network.segments = recipe.segments.filter { ids.contains(Int($0.key)!) }
  network.headers = recipe.headers.filter { header in
    ids.contains { $0 / clusterWidth == header.cluster }
  }
  if !network.files.isEmpty { try network.validate() }
  return network
}

func extractFirmwareRecipe(
  _ recipe: RangeRecipe, output: URL,
  cache: FirmwareRangeCache? = nil,
  progress: @Sendable (FirmwareExtractionProgress) -> Void,
  preferred: [String: Data] = [:]
) async throws -> Int {
  // Admission and publication failures never trigger a whole-IPSW fallback.
  let fullRecipe = recipe
  let recipe = try networkRecipe(recipe, preferred: preferred)
  try require(!exists(output), "Firmware output already exists.")
  let decoded: [Int: Data]
  if recipe.files.isEmpty {
    decoded = [:]
  } else {
    do {
      let header: Data
      if let cache {
        header = try await cache.fetch(recipe.source, record: recipe.zipHeader, base: 0)
      } else {
        header = try await fetchRange(recipe.source, record: recipe.zipHeader, base: 0)
      }
      try require(
        try header.part(0, 4) == Data([0x50, 0x4b, 3, 4]) && header.little(8, 2) == 0,
        "System image is not a stored ZIP member.")
      let nameSize = try header.little(26, 2)
      let extraSize = try header.little(28, 2)
      try require(
        try header.count == 30 + nameSize + extraSize
          && header.part(30, nameSize) == Data(recipe.systemImage.member.utf8),
        "ZIP member identity mismatch.")
      let records =
        [recipe.prefix] + recipe.headers.map(\.record)
        + recipe.segments.keys.sorted().compactMap { recipe.segments[$0] }
      let total = recipe.zipHeader.size + records.reduce(0) { $0 + $1.size }
      var completed = header.count
      progress(
        FirmwareExtractionProgress(
          stage: .downloading, completedBytes: completed, totalBytes: total))
      let fetched = try await withThrowingTaskGroup(of: (RangeRecord, Data).self) { group in
        var next = 0
        func submit(_ record: RangeRecord) {
          group.addTask {
            if let cache {
              return (
                record,
                try await cache.fetch(recipe.source, record: record, base: recipe.memberOffset)
              )
            }
            return (
              record, try await fetchRange(recipe.source, record: record, base: recipe.memberOffset)
            )
          }
        }
        while next < min(6, records.count) {
          submit(records[next])
          next += 1
        }
        var fetched: [RangeRecord: Data] = [:]
        while let (record, data) = try await group.next() {
          fetched[record] = data
          completed += data.count
          progress(
            FirmwareExtractionProgress(
              stage: .downloading, completedBytes: completed, totalBytes: total))
          if next < records.count {
            submit(records[next])
            next += 1
          }
        }
        return fetched
      }
      progress(
        FirmwareExtractionProgress(stage: .authenticating, completedBytes: total, totalBytes: total)
      )
      decoded = try await decodeRanges(recipe, fetched: fetched)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        throw CancellationError()
      }
      throw RestoreFailure(error.localizedDescription, fallback: true)
    }
  }
  let total =
    recipe.files.isEmpty
    ? 0
    : recipe.zipHeader.size + recipe.prefix.size
      + recipe.headers.reduce(0) { $0 + $1.size }
      + recipe.segments.values.reduce(0) { $0 + $1.size }
  progress(FirmwareExtractionProgress(stage: .writing, completedBytes: total, totalBytes: total))
  let workspace = try await cache?.publicationWorkspace(beside: output)
  try assembleRangeFiles(
    fullRecipe, decoded: decoded, output: output, workspace: workspace, preferred: preferred)
  progress(FirmwareExtractionProgress(stage: .complete, completedBytes: total, totalBytes: total))
  return total
}

// Retained for decoder regression tests; native callers use the admitted plan API.
func extractFirmwareRanges(_ path: URL, digest: String, output: URL) async throws {
  _ = try await extractFirmwareRecipe(
    readRecipe(path, digest: digest), output: output, progress: { _ in })
}
