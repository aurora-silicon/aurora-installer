// SPDX-License-Identifier: MIT
// The AEA range decoder: the archive prefix (header, metadata, root header),
// the cluster header's segment table and each segment. The fuzz build's
// crypto shims verify every MAC and make AES-CTR an identity, so the input's
// bytes are the plaintext the parser reads after each authentication.
//
// Input: decoded image size (4), system image size (4), segment offset (4),
// segment size (3), prefix size (3), the prefix, a cluster header, the segment.
import Foundation

@testable import AuroraFirmware

func fuzzHash(_ index: Int) -> String {
  String(repeating: "0", count: 62) + String(format: "%02x", index)
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzAEARanges(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  var fields = FuzzFields(fuzzData(bytes, count))
  let decodedBytes = fields.int(4)
  let systemBytes = fields.int(4)
  let segmentOffset = fields.int(4)
  let segmentSize = fields.int(3)
  let prefix = fields.bytes(fields.int(3))
  let cluster = fields.bytes(clusterHeaderBytes)
  let segment = fields.rest()

  // The metadata reader stands on its own: every AEA prefix passes through it.
  _ = try? metadata(prefix)

  let zipHeader = RangeRecord(offset: 0, size: 31, sha256: fuzzHash(1))
  let prefixRecord = RangeRecord(offset: 0, size: max(prefix.count, 1), sha256: fuzzHash(2))
  let header = ClusterRecord(
    offset: prefixRecord.size, size: clusterHeaderBytes, sha256: fuzzHash(3), cluster: 0,
    expectedMAC: fuzzHash(4))
  let segmentRecord = RangeRecord(
    offset: segmentOffset, size: max(segmentSize, 1), sha256: fuzzHash(5))
  let plain = min(max(decodedBytes, 1), segmentBytes)
  let recipe = RangeRecipe(
    schema: 1,
    source: SourceRecord(
      sizeBytes: systemBytes + 31, sha256: fuzzHash(6),
      url: "https://updates.cdn-apple.com/fuzz.ipsw"),
    systemImage: SystemRecord(
      sizeBytes: systemBytes, sha256: fuzzHash(7), member: "s",
      decoded: ImageRecord(sizeBytes: decodedBytes, sha256: fuzzHash(8))),
    memberOffset: 31, zipHeader: zipHeader, prefix: prefixRecord, headers: [header],
    segments: ["0": segmentRecord],
    files: [
      RangeFile(
        source: "s", name: "f", transform: "identity", compressed: false,
        rawSHA256: fuzzHash(9), sha256: fuzzHash(9), size: plain,
        storage: [
          StorageRecord(
            size: plain, sha256: fuzzHash(10), spans: [PlainSpan(offset: 0, size: plain)])
        ])
    ])
  // Production decodes only a validated recipe (`networkRecipe`).
  do { try recipe.validate() } catch {
    fuzzNote("recipe", error)
    return 0
  }
  let fetched = [prefixRecord: prefix, header.record: cluster, segmentRecord: segment]
  // The checks `decodeRanges(_:fetched:)` makes before it fetches the key.
  guard
    (try? prefix.count >= 156 && prefix.part(0, 4) == Data("AEA1".utf8)
      && prefix.little(4, 4) == 1) == true,
    let length = try? prefix.little(8, 4), length <= 1024 * 1024,
    prefix.count == 12 + length + 32 + 112, (try? metadata(prefix)) != nil
  else { return 0 }
  do { _ = try decodeRanges(recipe, fetched: fetched, archiveKey: Data(count: 32)) } catch {
    fuzzNote("decode", error)
  }
  return 0
}
