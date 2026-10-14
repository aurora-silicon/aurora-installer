#if os(macOS)
  import CryptoKit
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class OmarchyRemovalFATVolumeTests: XCTestCase {
    /// Made on macOS 26.6.2 by `newfs_msdos -F 32 -v "EFI - ASAHI"` on a 48 MiB
    /// raw disk image, filled through the FSKit msdos mount (two fillers were
    /// deleted before the asahi files were copied, so they reuse freed
    /// clusters), then marked dirty in both FATs as Linux leaves it. Stored as
    /// raw DEFLATE. The asahi files are the M1 Pro lab Mac's legacy evidence;
    /// m1n1/boot.bin is 20,000 seeded random bytes.
    func testDirtyVolumeMadeByNewfsMsdosIsReadWithoutMounting() throws {
      let image = try Self.fixture("fat32/newfs-msdos-dirty.img.deflate")
      XCTAssertEqual(image.count, 48 << 20)
      let volume = try Self.volume(image)
      let evidence = try XCTUnwrap(
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)
      ).appendingPathComponent("m1-pro-2026-09-28/legacy/evidence/esp-disk0s4")
      XCTAssertEqual(
        try volume.read(["asahi", "installer.log"], limit: 1 << 20),
        try Data(contentsOf: evidence.appendingPathComponent("asahi_installer.log")))
      XCTAssertEqual(
        try volume.read(["asahi", "stub_info.json"], limit: 1 << 20),
        try Data(contentsOf: evidence.appendingPathComponent("asahi_stub_info.json")))
      let boot = try XCTUnwrap(try volume.read(["m1n1", "boot.bin"], limit: 1 << 20))
      XCTAssertEqual(
        SHA256.hash(data: boot).map { String(format: "%02x", $0) }.joined(),
        "f6f48e1d5356f242cc6cec0796728e292f35bd92e072e252cfe5cbcd49678aad")
      XCTAssertEqual(
        try volume.read(["efi", "boot", "bootaa64.efi"], limit: 1024),
        Data(String(repeating: "efi", count: 100).utf8), "names match without case")
      XCTAssertEqual(try volume.read(["filler2"], limit: 8192), Data(repeating: 0x32, count: 5000))
      XCTAssertNil(try volume.read(["filler1"], limit: 8192), "deleted")
      XCTAssertNil(try volume.read(["asahi", "missing.json"], limit: 1024))
      XCTAssertNil(try volume.read(["missing", "installer.log"], limit: 1024))
      XCTAssertThrowsError(try volume.read(["asahi"], limit: 1024), "a directory isn’t a file")
      XCTAssertThrowsError(try volume.read(["filler2", "x"], limit: 1024), "nor a directory")
      XCTAssertThrowsError(try volume.read(["asahi", "installer.log"], limit: 5094), "limit")
    }

    func testLongNamesFragmentedChainsAndLargeSectors() throws {
      let log = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
      for (sector, perCluster) in [(512, 1), (4096, 1), (512, 8), (2048, 2)] {
        var builder = FATImageBuilder(sectorBytes: sector, sectorsPerCluster: perCluster)
        builder.fragment = true
        builder.dirty = true
        let image = builder.build([
          (
            "asahi", .directory([("installer.log", .file(log)), ("stub_info.json", .file(Data()))])
          ),
          ("M1N1", .directory([("BOOT.BIN", .file(Data("m1n1".utf8)))])),
          ("A Very Long Directory Name That Spans Records", .directory([("x", .file(Data([1])))])),
        ])
        let volume = try Self.volume(image.data)
        XCTAssertEqual(try volume.read(["asahi", "installer.log"], limit: 1 << 20), log)
        XCTAssertEqual(try volume.read(["asahi", "stub_info.json"], limit: 1), Data())
        XCTAssertEqual(try volume.read(["m1n1", "boot.bin"], limit: 64), Data("m1n1".utf8))
        XCTAssertEqual(
          try volume.read(["a very long directory name that spans records", "X"], limit: 1),
          Data([1]))
        XCTAssertEqual(
          try volume.read(["ASAHI~1", "installer.log"], limit: 1 << 20), log,
          "the 8.3 alias of a long name finds it too")
      }
    }

    func testDamagedChainsRefuse() throws {
      let builder = FATImageBuilder(sectorBytes: 512, sectorsPerCluster: 1)
      func damaged(_ change: (inout FATImageBuilder.Image, UInt32) -> Void) throws -> String {
        var image = builder.build([("log", .file(Data(repeating: 9, count: 2048)))])
        let first = image.firstCluster["log"]!
        change(&image, first)
        var message = ""
        XCTAssertThrowsError(try Self.volume(image.data).read(["log"], limit: 1 << 20)) {
          message = ($0 as? RemovalFailure)?.message ?? ""
        }
        return message
      }
      XCTAssertEqual(try damaged { $0.setFAT($1 + 1, $1) }, "log couldn’t be read safely.", "loop")
      XCTAssertEqual(
        try damaged { $0.setFAT($1 + 1, 0x0FFF_FFFF) }, "log couldn’t be read safely.", "short")
      XCTAssertEqual(
        try damaged {
          $0.setFAT($1 + 3, $1 + 4)
          $0.setFAT($1 + 4, 0x0FFF_FFFF)
        }, "log couldn’t be read safely.", "too long")
      XCTAssertEqual(
        try damaged { $0.setFAT($1 + 2, 0x0FFF_FFF7) }, "log couldn’t be read safely.", "bad")
      XCTAssertEqual(
        try damaged { $0.setFAT($1, 0x0FFF_FFF0) }, "log couldn’t be read safely.", "range")
      XCTAssertEqual(try damaged { $0.setFAT($1 + 1, 0) }, "log couldn’t be read safely.", "free")
    }

    func testAmbiguousOrMalformedEntriesRefuse() throws {
      let builder = FATImageBuilder(sectorBytes: 512, sectorsPerCluster: 1)
      let twice = builder.build([("stub.json", .file(Data([1]))), ("STUB.JSON", .file(Data([2])))])
      XCTAssertThrowsError(try Self.volume(twice.data).read(["stub.json"], limit: 8))
      var empty = builder.build([("empty", .file(Data()))])
      empty.setEntryCluster("empty", 5)
      XCTAssertThrowsError(try Self.volume(empty.data).read(["empty"], limit: 8))
      var orphan = builder.build([("dir", .directory([]))])
      orphan.setEntryCluster("dir", 0)
      XCTAssertThrowsError(try Self.volume(orphan.data).read(["dir", "x"], limit: 8))
      var brokenLong = builder.build([("installer.log", .file(Data([3])))])
      brokenLong.corruptLongNameChecksum("installer.log")
      XCTAssertNil(
        try Self.volume(brokenLong.data).read(["installer.log"], limit: 8),
        "a long name whose checksum doesn’t match its 8.3 record isn’t used")
    }

    func testBootSectorMustDescribeAFAT32ThatFitsThePartition() throws {
      let image = FATImageBuilder(sectorBytes: 512, sectorsPerCluster: 1).build([])
      XCTAssertNoThrow(try Self.volume(image.data))
      let changes: [(String, (inout Data) -> Void)] = [
        ("signature", { $0[510] = 0 }),
        ("jump", { $0[0] = 0 }),
        (
          "sector size",
          {
            $0[11] = 0
            $0[12] = 3
          }
        ),
        ("cluster size", { $0[13] = 3 }),
        (
          "reserved",
          {
            $0[14] = 0
            $0[15] = 0
          }
        ),
        ("FAT count", { $0[16] = 3 }),
        ("FAT16 root", { $0[17] = 0x10 }),
        ("FAT16 size", { $0[22] = 1 }),
        ("version", { $0[42] = 1 }),
        ("root cluster", { $0[44] = 1 }),
        ("active FAT", { $0[40] = 0x82 }),
        (
          "FAT too small",
          {
            $0[36] = 1
            $0[37] = 0
          }
        ),
        (
          "no data",
          {
            $0[32] = 40
            $0[33] = 0
          }
        ),
      ]
      for (label, change) in changes {
        var data = image.data
        change(&data)
        XCTAssertThrowsError(try Self.volume(data), label)
      }
      XCTAssertThrowsError(
        try RemovalFATVolume(size: UInt64(image.data.count - 512)) { offset, count in
          image.data.subdata(in: Int(offset)..<Int(offset) + count)
        }, "file system larger than the partition")
    }

    func testRawDeviceIdentifierAndGeometryAreChecked() {
      for identifier in [
        "disk0", "disk0s", "diskAs4", "disk0s4/../disk0", "../disk0s4", "rdisk0s4",
      ] {
        XCTAssertThrowsError(
          try RemovalFATVolume.rawDevice(identifier, blockSize: 4096, size: 524_288_000),
          identifier)
      }
      XCTAssertThrowsError(try RemovalFATVolume.rawDevice("disk0s4", blockSize: 1000, size: 4000))
      XCTAssertThrowsError(try RemovalFATVolume.rawDevice("disk0s4", blockSize: 4096, size: 4097))
      XCTAssertThrowsError(try RemovalFATVolume.rawDevice("disk0s4", blockSize: 4096, size: 0))
    }

    // MARK: Helpers

    static func volume(_ image: Data) throws -> RemovalFATVolume {
      try RemovalFATVolume(size: UInt64(image.count)) { offset, count in
        guard offset + UInt64(count) <= image.count else {
          throw RemovalFailure(message: "past the end")
        }
        return image.subdata(in: Int(offset)..<Int(offset) + count)
      }
    }

    static func fixture(_ path: String) throws -> Data {
      let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        .appendingPathComponent(path)
      return try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
    }
  }

  /// Builds small FAT32 images the way the specification lays them out: 32
  /// reserved sectors, two FATs, the root directory at cluster 2, VFAT long
  /// names for anything that isn't an upper-case 8.3 name.
  struct FATImageBuilder {
    indirect enum Node {
      case file(Data)
      case directory([(String, Node)])
    }

    struct Image {
      var data: Data
      let sectorBytes: Int
      let fatOffsets: [Int]
      /// Where each top-level entry's 8.3 record is.
      let records: [String: Int]
      /// Each entry's first cluster, by its path ("m1n1/boot.bin").
      let firstCluster: [String: UInt32]

      mutating func setFAT(_ cluster: UInt32, _ value: UInt32) {
        for offset in fatOffsets {
          let at = offset + Int(cluster) * 4
          for byte in 0..<4 { data[at + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
      }

      mutating func setEntryCluster(_ name: String, _ cluster: UInt32) {
        let at = records[name]!
        data[at + 20] = UInt8(truncatingIfNeeded: cluster >> 16)
        data[at + 21] = UInt8(truncatingIfNeeded: cluster >> 24)
        data[at + 26] = UInt8(truncatingIfNeeded: cluster)
        data[at + 27] = UInt8(truncatingIfNeeded: cluster >> 8)
      }

      mutating func corruptLongNameChecksum(_ name: String) {
        data[records[name]! - 32 + 13] ^= 0xFF
      }
    }

    let sectorBytes: Int
    let sectorsPerCluster: Int
    var clusters = 512
    var fragment = false
    var dirty = false

    init(sectorBytes: Int, sectorsPerCluster: Int) {
      self.sectorBytes = sectorBytes
      self.sectorsPerCluster = sectorsPerCluster
    }

    func build(_ root: [(String, Node)]) -> Image {
      let reserved = 32
      let fatSectors = ((clusters + 2) * 4 + sectorBytes - 1) / sectorBytes
      let total = reserved + 2 * fatSectors + clusters * sectorsPerCluster
      let clusterBytes = sectorBytes * sectorsPerCluster
      var data = Data(count: total * sectorBytes)
      func put(_ value: Int, _ width: Int, at: Int) {
        for byte in 0..<width { data[at + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
      }
      data.replaceSubrange(0..<3, with: [0xEB, 0x58, 0x90])
      data.replaceSubrange(3..<11, with: Array("BSD  4.4".utf8))
      put(sectorBytes, 2, at: 11)
      put(sectorsPerCluster, 1, at: 13)
      put(reserved, 2, at: 14)
      put(2, 1, at: 16)
      put(0xF8, 1, at: 21)
      put(total, 4, at: 32)
      put(fatSectors, 4, at: 36)
      put(2, 4, at: 44)
      put(1, 2, at: 48)
      put(6, 2, at: 50)
      put(0x29, 1, at: 66)
      data.replaceSubrange(71..<90, with: Array("EFI - ASAHIFAT32   ".utf8))
      data[510] = 0x55
      data[511] = 0xAA

      var fat = [UInt32](repeating: 0, count: clusters + 2)
      fat[0] = 0x0FFF_FFF8
      fat[1] = dirty ? 0x07FF_FFFF : 0x0FFF_FFFF
      var next: UInt32 = 2
      func allocate(_ count: Int) -> [UInt32] {
        var chain = [UInt32]()
        for _ in 0..<max(count, 1) {
          chain.append(next)
          next += fragment && !chain.isEmpty && next > 2 ? 2 : 1
        }
        for (index, cluster) in chain.enumerated() {
          fat[Int(cluster)] = index + 1 < chain.count ? chain[index + 1] : 0x0FFF_FFFF
        }
        return chain
      }
      let dataStart = (reserved + 2 * fatSectors) * sectorBytes
      func offset(_ cluster: UInt32) -> Int { dataStart + Int(cluster - 2) * clusterBytes }
      func write(_ bytes: Data, _ chain: [UInt32]) {
        for (index, cluster) in chain.enumerated() {
          let piece = bytes.dropFirst(index * clusterBytes).prefix(clusterBytes)
          data.replaceSubrange(offset(cluster)..<offset(cluster) + piece.count, with: piece)
        }
      }

      var records = [String: Int]()
      var firstCluster = [String: UInt32]()
      func directory(
        _ children: [(String, Node)], chain: [UInt32], parent: UInt32?, prefix: String = ""
      ) {
        var entries = Data()
        var recordAt = [String: Int]()
        if let parent {
          entries.append(
            Self.record(Array(".          ".utf8), attributes: 0x10, cluster: chain[0]))
          entries.append(
            Self.record(
              Array("..         ".utf8), attributes: 0x10, cluster: parent == 2 ? 0 : parent))
        }
        var pending = [(String, [(String, Node)], [UInt32])]()
        for (index, (name, node)) in children.enumerated() {
          let short = Self.shortName(name, index: index + 1)
          if short.long {
            entries.append(Self.longRecords(name, checksum: Self.checksum(short.bytes)))
          }
          let cluster: UInt32
          let size: Int
          switch node {
          case .file(let bytes):
            size = bytes.count
            if bytes.isEmpty {
              cluster = 0
            } else {
              let chain = allocate((bytes.count + clusterBytes - 1) / clusterBytes)
              write(bytes, chain)
              cluster = chain[0]
            }
            recordAt[name] = entries.count
            entries.append(
              Self.record(short.bytes, attributes: 0x20, cluster: cluster, size: size))
          case .directory(let grandchildren):
            let chain = allocate(Self.directoryClusters(grandchildren, clusterBytes))
            cluster = chain[0]
            recordAt[name] = entries.count
            entries.append(Self.record(short.bytes, attributes: 0x10, cluster: cluster))
            pending.append((prefix + name + "/", grandchildren, chain))
          }
          firstCluster[prefix + name] = cluster
        }
        write(entries, chain)
        if parent == nil {
          for (name, at) in recordAt {
            records[name] = offset(chain[at / clusterBytes]) + at % clusterBytes
          }
        }
        for (path, grandchildren, childChain) in pending {
          directory(grandchildren, chain: childChain, parent: chain[0], prefix: path)
        }
      }
      let rootChain = allocate(Self.directoryClusters(root, clusterBytes, root: true))
      directory(root, chain: rootChain, parent: nil)

      var fatBytes = Data(count: fatSectors * sectorBytes)
      for (index, value) in fat.enumerated() {
        for byte in 0..<4 {
          fatBytes[index * 4 + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
        }
      }
      let fatOffsets = [reserved * sectorBytes, (reserved + fatSectors) * sectorBytes]
      for at in fatOffsets { data.replaceSubrange(at..<at + fatBytes.count, with: fatBytes) }
      return Image(
        data: data, sectorBytes: sectorBytes, fatOffsets: fatOffsets, records: records,
        firstCluster: firstCluster)
    }

    /// An EFI partition holding the files removal reads from it.
    static func esp(_ files: RemovalInstallFiles, dirty: Bool = false) -> Image {
      var builder = FATImageBuilder(sectorBytes: 4096, sectorsPerCluster: 1)
      builder.dirty = dirty
      builder.clusters = 2048
      var m1n1 = [(String, Node)]()
      var asahi = [(String, Node)]()
      if let boot = files.espBootObject { m1n1.append(("boot.bin", .file(boot))) }
      if let info = files.stubInfo { asahi.append(("stub_info.json", .file(info))) }
      if let log = files.installerLog { asahi.append(("installer.log", .file(log))) }
      return builder.build([
        ("EFI", .directory([("BOOT", .directory([]))])), ("m1n1", .directory(m1n1)),
        ("asahi", .directory(asahi)),
      ])
    }

    private static func directoryClusters(
      _ children: [(String, Node)], _ clusterBytes: Int, root: Bool = false
    ) -> Int {
      var count = root ? 0 : 2
      for (index, (name, _)) in children.enumerated() {
        count += 1 + (shortName(name, index: index + 1).long ? (name.utf16.count + 12) / 13 : 0)
      }
      return max(1, (count * 32 + clusterBytes - 1) / clusterBytes)
    }

    private static func shortName(_ name: String, index: Int) -> (bytes: [UInt8], long: Bool) {
      let parts = name.split(separator: ".", omittingEmptySubsequences: false)
      let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~")
      if parts.count <= 2, let base = parts.first, (1...8).contains(base.count),
        parts.count == 1 || (1...3).contains(parts[1].count),
        parts.joined().allSatisfy(allowed.contains)
      {
        let ext = parts.count == 2 ? String(parts[1]) : ""
        return (
          Array(
            (base.padding(toLength: 8, withPad: " ", startingAt: 0)
              + ext.padding(toLength: 3, withPad: " ", startingAt: 0)).utf8), false
        )
      }
      let letters = name.uppercased().filter(allowed.contains).filter { $0 != "~" }
      let base = String(letters.prefix(6)) + "~\(index)"
      return (Array((base.padding(toLength: 8, withPad: " ", startingAt: 0) + "   ").utf8), true)
    }

    private static func checksum(_ short: [UInt8]) -> UInt8 {
      var sum: UInt8 = 0
      for byte in short { sum = (sum >> 1 | (sum & 1) << 7) &+ byte }
      return sum
    }

    private static func longRecords(_ name: String, checksum: UInt8) -> Data {
      var units = Array(name.utf16)
      if units.count % 13 != 0 { units.append(0) }
      while units.count % 13 != 0 { units.append(0xFFFF) }
      let count = units.count / 13
      var result = Data()
      for order in stride(from: count, through: 1, by: -1) {
        var record = [UInt8](repeating: 0, count: 32)
        record[0] = UInt8(order) | (order == count ? 0x40 : 0)
        record[11] = 0x0F
        record[13] = checksum
        let piece = units[(order - 1) * 13..<order * 13]
        let slots =
          Array(stride(from: 1, to: 11, by: 2)) + Array(stride(from: 14, to: 26, by: 2))
          + Array(stride(from: 28, to: 32, by: 2))
        for (slot, unit) in zip(slots, piece) {
          record[slot] = UInt8(truncatingIfNeeded: unit)
          record[slot + 1] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        result.append(contentsOf: record)
      }
      return result
    }

    private static func record(
      _ short: [UInt8], attributes: UInt8, cluster: UInt32, size: Int = 0
    ) -> Data {
      var record = [UInt8](repeating: 0, count: 32)
      record.replaceSubrange(0..<11, with: short)
      record[11] = attributes
      record[20] = UInt8(truncatingIfNeeded: cluster >> 16)
      record[21] = UInt8(truncatingIfNeeded: cluster >> 24)
      record[26] = UInt8(truncatingIfNeeded: cluster)
      record[27] = UInt8(truncatingIfNeeded: cluster >> 8)
      for byte in 0..<4 { record[28 + byte] = UInt8(truncatingIfNeeded: size >> (8 * byte)) }
      return Data(record)
    }
  }
#endif
