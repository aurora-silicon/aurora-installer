#if os(macOS)
  import Darwin
  import Foundation

  /// Something removal reads the installation's small files from.
  protocol RemovalFileReading {
    /// The file's contents, nil when the path doesn't exist. Throws when a
    /// component has the wrong type or the file is larger than `limit`.
    func read(_ components: [String], limit: Int) throws -> Data?
  }

  extension RemovalFileTree: RemovalFileReading {}

  /// Reads files from a FAT32 file system without mounting it. An EFI partition
  /// that Linux didn't cleanly unmount is a dirty FAT: DiskArbitration refuses
  /// to mount it, and FSKit's msdos module (macOS 26) mounts it read-only but
  /// then never finishes unmounting it. Reading the file system's own records
  /// needs neither, can't change the partition, and ignores the dirty flag.
  ///
  /// Every structure is checked before it is used: the boot sector's geometry
  /// must fit the partition, cluster chains must stay in range, end where the
  /// file's size says, and never revisit a cluster, and a name must match only
  /// one directory entry.
  final class RemovalFATVolume: RemovalFileReading {
    /// Returns exactly `count` bytes at `offset` in the partition.
    typealias Reader = (_ offset: UInt64, _ count: Int) throws -> Data

    private static let endOfChain: UInt32 = 0x0FFF_FFF8
    private static let maximumDirectoryBytes = 65_536 * 32
    private static let maximumRun = 1 << 20

    private let reader: Reader
    private let sectorBytes: Int
    private let clusterBytes: Int
    private let fatOffset: UInt64
    private let dataOffset: UInt64
    private let highestCluster: UInt32
    private let rootCluster: UInt32
    private var fatSectors = [UInt64: Data]()

    init(size: UInt64, read: @escaping Reader) throws {
      reader = { offset, count in
        let bytes = try read(offset, count)
        guard bytes.count == count else { throw Self.unreadable }
        return Data(bytes)
      }
      let boot = try reader(0, 512)
      func u8(_ at: Int) -> Int { Int(boot[at]) }
      func u16(_ at: Int) -> Int { Int(boot[at]) | Int(boot[at + 1]) << 8 }
      func u32(_ at: Int) -> UInt32 {
        UInt32(boot[at]) | UInt32(boot[at + 1]) << 8 | UInt32(boot[at + 2]) << 16
          | UInt32(boot[at + 3]) << 24
      }
      let sector = u16(11)
      let perCluster = u8(13)
      let reserved = u16(14)
      let fats = u8(16)
      let total = u16(19) != 0 ? UInt64(u16(19)) : UInt64(u32(32))
      let fatSectors = UInt64(u32(36))
      let flags = u16(40)
      let active = flags & 0x80 != 0 ? flags & 0x0F : 0
      guard [0xEB, 0xE9].contains(boot[0]), boot[510] == 0x55, boot[511] == 0xAA,
        [512, 1024, 2048, 4096].contains(sector),
        perCluster > 0, perCluster <= 128, perCluster & (perCluster - 1) == 0,
        reserved > 0, (1...2).contains(fats), active < fats,
        u16(17) == 0, u16(22) == 0, u16(42) == 0, fatSectors > 0, total > 0,
        total * UInt64(sector) <= size
      else { throw Self.unreadable }
      let data = UInt64(reserved) + UInt64(fats) * fatSectors
      guard data < total else { throw Self.unreadable }
      let clusters = (total - data) / UInt64(perCluster)
      guard clusters > 0, clusters + 2 <= fatSectors * UInt64(sector) / 4,
        clusters + 1 < UInt64(Self.endOfChain - 1)
      else { throw Self.unreadable }
      sectorBytes = sector
      clusterBytes = sector * perCluster
      fatOffset = (UInt64(reserved) + UInt64(active) * fatSectors) * UInt64(sector)
      dataOffset = data * UInt64(sector)
      highestCluster = UInt32(clusters + 1)
      rootCluster = u32(44) & 0x0FFF_FFFF
      guard (2...highestCluster).contains(rootCluster) else { throw Self.unreadable }
    }

    /// Reads the partition through its raw device, in whole device blocks.
    static func rawDevice(_ identifier: String, blockSize: Int, size: UInt64) throws
      -> RemovalFATVolume
    {
      guard isPartitionIdentifier(identifier),
        (512...65_536).contains(blockSize), blockSize & (blockSize - 1) == 0,
        size > 0, size % UInt64(blockSize) == 0
      else { throw unreadable }
      let device = try RawDevice("/dev/r" + identifier)
      return try RemovalFATVolume(size: size) { offset, count in
        try device.read(offset, count, blockSize: blockSize, size: size)
      }
    }

    /// "disk<N>s<M>", nothing else, so the device path can't be steered.
    private static func isPartitionIdentifier(_ identifier: String) -> Bool {
      guard identifier.hasPrefix("disk") else { return false }
      let parts = identifier.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
      return parts.count == 2
        && parts.allSatisfy {
          !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    func read(_ components: [String], limit: Int) throws -> Data? {
      let path = components.joined(separator: "/")
      var directory = rootCluster
      for (index, component) in components.enumerated() {
        guard let entry = try find(component, in: directory, path: path) else { return nil }
        let last = index == components.count - 1
        guard entry.isDirectory == !last else { throw Self.failure(path) }
        if !last {
          guard (2...highestCluster).contains(entry.cluster) else { throw Self.failure(path) }
          directory = entry.cluster
          continue
        }
        guard entry.size <= limit else { throw Self.failure(path) }
        guard entry.size > 0 else {
          guard entry.cluster == 0 else { throw Self.failure(path) }
          return Data()
        }
        let needed = (entry.size + clusterBytes - 1) / clusterBytes
        let chain = try self.chain(from: entry.cluster, count: needed, path: path)
        var contents = try readClusters(chain, path: path)
        contents.removeSubrange(entry.size...)
        return contents
      }
      return nil
    }

    // MARK: Directories

    private struct Entry {
      let isDirectory: Bool
      let cluster: UInt32
      let size: Int
    }

    private func find(_ name: String, in cluster: UInt32, path: String) throws -> Entry? {
      let wanted = name.lowercased()
      let chain = try self.chain(
        from: cluster, count: nil, limit: Self.maximumDirectoryBytes / clusterBytes, path: path)
      let records = try readClusters(chain, path: path)
      var found: Entry?
      var long = LongName()
      for start in stride(from: 0, to: records.count, by: 32) {
        let record = records[start..<start + 32]
        let first = record[start]
        if first == 0 { break }
        let attributes = record[start + 11]
        if first == 0xE5 {
          long = LongName()
          continue
        }
        if attributes & 0x3F == 0x0F {
          long.add(record, at: start)
          continue
        }
        let shortName = Array(record[start..<start + 11])
        let longName = long.name(for: shortName)
        long = LongName()
        if attributes & 0x08 != 0 { continue }
        guard
          longName?.lowercased() == wanted || Self.shortName(shortName).lowercased() == wanted
        else { continue }
        guard found == nil else { throw Self.failure(path) }
        func u16(_ at: Int) -> UInt32 {
          UInt32(record[start + at]) | UInt32(record[start + at + 1]) << 8
        }
        found = Entry(
          isDirectory: attributes & 0x10 != 0,
          cluster: (u16(20) << 16 | u16(26)) & 0x0FFF_FFFF,
          size: Int(u16(28) | u16(30) << 16))
      }
      return found
    }

    /// "NAME.EXT" from an 8.3 record; 0x05 stands for a leading 0xE5.
    private static func shortName(_ bytes: [UInt8]) -> String {
      var raw = bytes
      if raw[0] == 0x05 { raw[0] = 0xE5 }
      func text(_ part: ArraySlice<UInt8>) -> String {
        String(decoding: part.reversed().drop { $0 == 0x20 }.reversed(), as: UTF8.self)
      }
      let base = text(raw[0..<8])
      let ext = text(raw[8..<11])
      return ext.isEmpty ? base : base + "." + ext
    }

    /// Collects VFAT long-name records, which precede their 8.3 record from
    /// the last piece to the first, each carrying the 8.3 name's checksum.
    private struct LongName {
      private var pieces = [Int: [UInt16]]()
      private var expected = 0
      private var checksum: UInt8 = 0
      private var broken = false

      mutating func add(_ record: Data, at start: Int) {
        let order = Int(record[start] & 0x3F)
        if record[start] & 0x40 != 0 {
          pieces = [:]
          broken = !(1...20).contains(order)
          expected = order
          checksum = record[start + 13]
        } else if order != expected || record[start + 13] != checksum {
          broken = true
        }
        guard !broken, order == expected else { return }
        var units = [UInt16]()
        for range in [1..<11, 14..<26, 28..<32] {
          for at in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
            units.append(UInt16(record[start + at]) | UInt16(record[start + at + 1]) << 8)
          }
        }
        pieces[order] = units
        expected -= 1
      }

      func name(for shortName: [UInt8]) -> String? {
        guard !broken, !pieces.isEmpty, expected == 0 else { return nil }
        var sum: UInt8 = 0
        for byte in shortName { sum = (sum >> 1 | (sum & 1) << 7) &+ byte }
        guard sum == checksum else { return nil }
        let units = pieces.keys.sorted().flatMap { pieces[$0]! }.prefix { $0 != 0 }
        return String(decoding: Array(units), as: UTF16.self)
      }
    }

    // MARK: Clusters

    /// Follows a chain from `first`. With `count`, it must end exactly after
    /// that many clusters; otherwise it may hold at most `limit`.
    private func chain(from first: UInt32, count: Int?, limit: Int = 0, path: String) throws
      -> [UInt32]
    {
      var chain = [UInt32]()
      var seen = Set<UInt32>()
      var cluster = first
      let maximum = count ?? max(limit, 1)
      while true {
        guard (2...highestCluster).contains(cluster), seen.insert(cluster).inserted,
          chain.count < maximum
        else { throw Self.failure(path) }
        chain.append(cluster)
        let next = try fatEntry(cluster)
        if next >= Self.endOfChain { break }
        cluster = next
      }
      if let count, chain.count != count { throw Self.failure(path) }
      return chain
    }

    private func fatEntry(_ cluster: UInt32) throws -> UInt32 {
      let offset = fatOffset + UInt64(cluster) * 4
      let sector = offset / UInt64(sectorBytes)
      let bytes: Data
      if let cached = fatSectors[sector] {
        bytes = cached
      } else {
        bytes = try reader(sector * UInt64(sectorBytes), sectorBytes)
        fatSectors[sector] = bytes
      }
      let at = Int(offset % UInt64(sectorBytes))
      let value =
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
        | UInt32(bytes[at + 3]) << 24
      return value & 0x0FFF_FFFF
    }

    /// Reads the clusters in order, coalescing neighbours into larger reads.
    private func readClusters(_ chain: [UInt32], path: String) throws -> Data {
      var contents = Data()
      var index = 0
      while index < chain.count {
        var run = 1
        while index + run < chain.count, chain[index + run] == chain[index] + UInt32(run),
          (run + 1) * clusterBytes <= Self.maximumRun
        {
          run += 1
        }
        let offset = dataOffset + UInt64(chain[index] - 2) * UInt64(clusterBytes)
        let bytes = try reader(offset, run * clusterBytes)
        guard bytes.count == run * clusterBytes else { throw Self.failure(path) }
        contents.append(bytes)
        index += run
      }
      return contents
    }

    private static var unreadable: RemovalFailure {
      RemovalFailure(
        message: "The EFI partition isn’t a FAT32 file system that can be read safely.")
    }

    private static func failure(_ path: String) -> RemovalFailure {
      RemovalFailure(message: "\(path) couldn’t be read safely.")
    }
  }

  /// A raw disk device opened read-only; reads are rounded out to whole blocks.
  private final class RawDevice {
    private let descriptor: Int32

    init(_ path: String) throws {
      descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      var info = stat()
      guard descriptor >= 0, fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR
      else {
        if descriptor >= 0 { close(descriptor) }
        throw RemovalFailure(message: "\(path) couldn’t be opened for reading.")
      }
    }

    deinit { close(descriptor) }

    func read(_ offset: UInt64, _ count: Int, blockSize: Int, size: UInt64) throws -> Data {
      let block = UInt64(blockSize)
      let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
      guard count > 0, !overflow, end <= size else {
        throw RemovalFailure(message: "A read went past the end of the EFI partition.")
      }
      let start = offset / block * block
      let stop = (end + block - 1) / block * block
      var buffer = [UInt8](repeating: 0, count: Int(stop - start))
      var done = 0
      while done < buffer.count {
        let got = buffer.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress! + done, $0.count - done, off_t(start) + off_t(done))
        }
        if got < 0, errno == EINTR { continue }
        guard got > 0 else {
          throw RemovalFailure(message: "The EFI partition couldn’t be read.")
        }
        done += got
      }
      let from = Int(offset - start)
      return Data(buffer[from..<from + count])
    }
  }
#endif
