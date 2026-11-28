import Foundation

// RestoreImageMember against Python's zipfile (Fixtures/RestoreImageMember,
// generate.py) and against archives built here, ZIP64 like every current
// restore image, with each record broken in turn.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }
  static func expectThrows(
    _ what: String, _ failure: RestoreImageMember.Failure, _ body: () throws -> Void
  ) {
    do {
      try body()
      expect(false, "\(what): no error")
    } catch let error as RestoreImageMember.Failure {
      expect(error == failure, "\(what): \(error), expected \(failure)")
    } catch {
      expect(false, "\(what): \(error)")
    }
  }

  static func locate(_ name: String, in archive: [UInt8]) throws -> RestoreImageMember {
    try RestoreImageMember.locate(name, archiveSize: archive.count) { offset, count in
      Data(archive[offset..<(offset + count)])
    }
  }

  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    return ~crc
  }

  static func le(_ value: Int, _ width: Int) -> [UInt8] {
    (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
  }

  /// A ZIP64 archive the way restore images are laid out: local headers
  /// with name and no extra, central entries whose sizes and offset are
  /// 0xffffffff with a ZIP64 extra field, then the ZIP64 end record, its
  /// locator and the end record with 0xffff/0xffffffff placeholders.
  struct Entry {
    var name: String
    var data: [UInt8]
    var method = 0
    var flags = 0
    var localExtra: [UInt8] = []
    var localName: String?
    var localCRC: UInt32?
    var localFlags: Int?
    var centralExtra: [UInt8]?
    var disk = 0
    var comment: [UInt8] = []
  }
  struct Layout {
    var entries: [Entry]
    var comment: [UInt8] = []
    var endDisk = 0
    var locatorDisks = 1
    var recordSize: Int?
    var directorySize: Int?
    var directoryOffset: Int?
    var zip64 = true
    var trailingEntryBytes: [UInt8] = []
    var entryCount: Int?
  }

  static func build(_ layout: Layout) -> (bytes: [UInt8], offsets: [Int]) {
    var out: [UInt8] = []
    var central: [UInt8] = []
    var offsets: [Int] = []
    for entry in layout.entries {
      let header = out.count
      let name = [UInt8](entry.name.utf8)
      let localName = [UInt8]((entry.localName ?? entry.name).utf8)
      let crc = crc32(entry.data)
      out += le(0x0403_4b50, 4) + le(45, 2) + le(entry.localFlags ?? entry.flags, 2)
      out += le(entry.method, 2) + le(0, 4)
      out += le(Int(entry.localCRC ?? crc), 4) + le(entry.data.count, 4) + le(entry.data.count, 4)
      out += le(localName.count, 2) + le(entry.localExtra.count, 2) + localName + entry.localExtra
      offsets.append(out.count)
      out += entry.data
      let extra =
        entry.centralExtra
        ?? (layout.zip64
          ? le(1, 2) + le(24, 2) + le(entry.data.count, 8) + le(entry.data.count, 8)
            + le(header, 8) : [])
      let wide = layout.zip64
      central += le(0x0201_4b50, 4) + le(45, 2) + le(45, 2) + le(entry.flags, 2)
      central += le(entry.method, 2) + le(0, 4) + le(Int(crc), 4)
      central += le(wide ? 0xffff_ffff : entry.data.count, 4)
      central += le(wide ? 0xffff_ffff : entry.data.count, 4)
      central += le(name.count, 2) + le(extra.count, 2) + le(entry.comment.count, 2)
      central += le(entry.disk, 2) + le(0, 2) + le(0, 4) + le(wide ? 0xffff_ffff : header, 4)
      central += name + extra + entry.comment
    }
    central += layout.trailingEntryBytes
    let directoryOffset = layout.directoryOffset ?? out.count
    let directorySize = layout.directorySize ?? central.count
    out += central
    if layout.zip64 {
      let record = out.count
      out += le(0x0606_4b50, 4) + le(layout.recordSize ?? 44, 8) + le(45, 2) + le(45, 2)
      let count = layout.entryCount ?? layout.entries.count
      out += le(0, 4) + le(0, 4) + le(count, 8) + le(count, 8)
      out += le(directorySize, 8) + le(directoryOffset, 8)
      out += le(0x0706_4b50, 4) + le(0, 4) + le(record, 8) + le(layout.locatorDisks, 4)
      out += le(0x0605_4b50, 4) + le(layout.endDisk, 2) + le(0, 2) + le(0xffff, 2) + le(0xffff, 2)
      out += le(0xffff_ffff, 4) + le(0xffff_ffff, 4)
    } else {
      out += le(0x0605_4b50, 4) + le(layout.endDisk, 2) + le(0, 2)
      out += le(layout.entries.count, 2) + le(layout.entries.count, 2)
      out += le(directorySize, 4) + le(directoryOffset, 4)
    }
    out += le(layout.comment.count, 2) + layout.comment
    return (out, offsets)
  }

  static func main() throws {
    // Python's zipfile: a classic archive and a ZIP64 one (force_zip64).
    let fixtures = URL(fileURLWithPath: "Tests/Fixtures/RestoreImageMember")
    let expected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
      as! [String: [String: [String: Any]]]
    for (file, members) in expected.sorted(by: { $0.key < $1.key }) {
      let archive = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent(file)))
      for (name, want) in members.sorted(by: { $0.key < $1.key }) {
        if want["stored"] as! Bool {
          let found = try? locate(name, in: archive)
          expect(
            found?.offset == want["offset"] as? Int && found?.size == want["size"] as? Int
              && found?.crc32 == UInt32(want["crc32"] as! Int),
            "\(file) \(name): \(String(describing: found))")
        } else {
          expectThrows("\(file) \(name) (deflated)", .notStored) {
            _ = try locate(name, in: archive)
          }
        }
      }
      expectThrows("\(file) missing member", .missing) { _ = try locate("none", in: archive) }
    }

    // Archives built here.
    let a = Entry(name: "141-1-1.dmg.aea", data: [UInt8]("AEA1 first member".utf8))
    let b = Entry(name: "BuildManifest.plist", data: [UInt8](repeating: 0x3c, count: 300))
    let c = Entry(name: "Firmware/x.im4p", data: [1, 2, 3])
    let good = Layout(entries: [a, b, c])
    let (bytes, offsets) = build(good)
    for (index, entry) in good.entries.enumerated() {
      let found = try? locate(entry.name, in: bytes)
      expect(
        found
          == RestoreImageMember(
            name: entry.name, offset: offsets[index], size: entry.data.count,
            crc32: crc32(entry.data)), "ZIP64 \(entry.name)")
      if let found {
        expect(
          Array(bytes[found.offset..<(found.offset + found.size)]) == entry.data,
          "ZIP64 \(entry.name) bytes")
      }
    }
    expectThrows("name is a prefix of a member", .missing) { _ = try locate("141-1-1", in: bytes) }
    expectThrows("empty name", .invalidArchive) { _ = try locate("", in: bytes) }

    // The end record found behind a comment of the largest size, and a
    // comment that itself holds an end record signature.
    var commented = good
    commented.comment = [UInt8](repeating: 0x20, count: 65535)
    expect((try? locate(c.name, in: build(commented).bytes))?.size == 3, "65535-byte comment")
    commented.comment = le(0x0605_4b50, 4) + [UInt8](repeating: 0, count: 30)
    expect((try? locate(c.name, in: build(commented).bytes))?.size == 3, "comment with a signature")
    // A comment that is itself a complete end record (comment length 0)
    // gives two places the end record could be: refused, not guessed.
    // Classic, so the inner record alone would also parse.
    var twice = good
    twice.zip64 = false
    twice.comment = Array(build(twice).bytes.suffix(22))
    expectThrows("comment holding a second end record", .invalidArchive) {
      _ = try locate(c.name, in: build(twice).bytes)
    }
    var classic = good
    classic.zip64 = false
    expect((try? locate(b.name, in: build(classic).bytes))?.size == 300, "classic archive")

    // A local extra field the central entry doesn't have moves the data.
    var moved = good
    moved.entries[1].localExtra = le(0x5455, 2) + le(5, 2) + [1, 2, 3, 4, 5]
    let (movedBytes, movedOffsets) = build(moved)
    expect((try? locate(b.name, in: movedBytes))?.offset == movedOffsets[1], "local extra field")

    // Refusals.
    func refuses(
      _ what: String, _ failure: RestoreImageMember.Failure, _ layout: Layout, _ name: String
    ) {
      expectThrows(what, failure) { _ = try locate(name, in: build(layout).bytes) }
    }
    var bad = good
    bad.entries[1].method = 8
    refuses("deflated member", .notStored, bad, b.name)
    bad = good
    bad.entries[1].flags = 1
    refuses("encrypted member", .notStored, bad, b.name)
    bad = good
    bad.entries.append(Entry(name: b.name, data: [9]))
    refuses("duplicate name", .invalidArchive, bad, b.name)
    bad = good
    bad.endDisk = 1
    refuses("end record on disk 1", .invalidArchive, bad, b.name)
    bad = good
    bad.locatorDisks = 2
    refuses("two disks", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].disk = 1
    refuses("member on disk 1", .invalidArchive, bad, b.name)
    bad = good
    bad.recordSize = 52
    refuses("ZIP64 end record size", .invalidArchive, bad, b.name)
    bad = good
    bad.directoryOffset = bytes.count
    refuses("directory past the end", .invalidArchive, bad, b.name)
    bad = good
    bad.directorySize = 17 * 1024 * 1024
    refuses("directory over 16 MiB", .invalidArchive, bad, b.name)
    bad = good
    // The directory runs from the end of the last member to the ZIP64 end
    // record (56 bytes), its locator (20) and the end record (22).
    let directorySize = bytes.count - 98 - (offsets[2] + c.data.count)
    bad.directorySize = directorySize - 1
    refuses("directory one byte short", .invalidArchive, bad, b.name)
    // u64 values over Int.max (negative as Int) are refused, not trapped on.
    bad = good
    bad.directorySize = Int.min
    refuses("directory size 2^63", .invalidArchive, bad, b.name)
    bad = good
    bad.entryCount = -1
    bad.directorySize = 0
    refuses("entry count 2^64 - 1, empty directory", .invalidArchive, bad, b.name)
    bad = good
    bad.directoryOffset = Int.min
    refuses("directory offset 2^63", .invalidArchive, bad, b.name)
    bad = good
    bad.entryCount = 2
    refuses("entry count short of the entries", .invalidArchive, bad, b.name)
    bad = good
    bad.trailingEntryBytes = [0]
    refuses("byte after the last entry", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].localName = "BuildManifest.plisT"
    refuses("local name differs", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].localFlags = 1
    refuses("encrypted in the local header only", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].localCRC = 1
    refuses("local CRC differs", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].centralExtra = le(1, 2) + le(16, 2) + le(300, 8) + le(300, 8)
    refuses("ZIP64 extra without the header offset", .invalidArchive, bad, b.name)
    bad = good
    bad.entries[1].centralExtra = le(1, 2) + le(30, 2) + [UInt8](repeating: 0, count: 24)
    refuses("ZIP64 extra longer than its field", .invalidArchive, bad, b.name)

    // Byte-level damage to the archive built above.
    func damaged(_ what: String, _ failure: RestoreImageMember.Failure, at: Int, _ value: UInt8) {
      var copy = bytes
      copy[at] = value
      expectThrows(what, failure) { _ = try locate(b.name, in: copy) }
    }
    damaged("local signature", .invalidArchive, at: offsets[1] - 30 - b.name.utf8.count, 0)
    damaged("end record signature", .invalidArchive, at: bytes.count - 22, 0)
    damaged("locator signature", .invalidArchive, at: bytes.count - 42, 0)
    damaged("ZIP64 end record signature", .invalidArchive, at: bytes.count - 98, 0)
    // The member's data would run into the central directory.
    var long = good
    long.entries[2].centralExtra =
      le(1, 2) + le(24, 2) + le(4, 8) + le(4, 8) + le(offsets[2] - 30 - c.name.utf8.count, 8)
    refuses("member runs into the directory", .invalidArchive, long, c.name)

    // A directory over 16 MiB, otherwise well formed: 260 entries with
    // comments of 65535 bytes (about 17 MB) ahead of the member.
    var huge = good
    huge.entries =
      (0..<260).map {
        Entry(name: "pad\($0)", data: [], comment: [UInt8](repeating: 0x2e, count: 65535))
      } + [b]
    refuses("directory over 16 MiB", .invalidArchive, huge, b.name)
    huge.entries.removeFirst(60)
    expect((try? locate(b.name, in: build(huge).bytes))?.size == 300, "directory under 16 MiB")

    // A ZIP64 field without the header offset, followed by a field whose
    // first bytes read as the right offset: the value is not taken from
    // past the ZIP64 field.
    let bHeader = offsets[1] - 30 - b.name.utf8.count
    bad = good
    bad.entries[1].centralExtra =
      le(1, 2) + le(16, 2) + le(300, 8) + le(300, 8) + le(bHeader, 2) + le(0, 2) + le(0, 4)
    refuses("ZIP64 value read past its field", .invalidArchive, bad, b.name)

    // Over 4 GiB, as every restore image is: a sparse archive whose member's
    // local header is at `header`, read through the same closure. Without a
    // ZIP64 field (`zip64: false`: the entry keeps its sizes and has only the
    // offset as 0xffffffff), that 0xffffffff must not be taken as the offset,
    // even where a local header sits there.
    func sparse(header: Int, zip64: Bool) throws -> RestoreImageMember {
      let name = [UInt8]("141-9-9.dmg.aea".utf8)
      let data = [UInt8]("AEA1 sparse".utf8)
      var local = le(0x0403_4b50, 4) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4)
      local += le(Int(crc32(data)), 4) + le(data.count, 4) + le(data.count, 4)
      local += le(name.count, 2) + le(0, 2) + name + data
      let directoryAt = header + local.count
      let extra =
        zip64 ? le(1, 2) + le(24, 2) + le(data.count, 8) + le(data.count, 8) + le(header, 8) : []
      let sizes = zip64 ? 0xffff_ffff : data.count
      var tail = le(0x0201_4b50, 4) + le(45, 2) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 4)
      tail += le(Int(crc32(data)), 4) + le(sizes, 4) + le(sizes, 4)
      tail += le(name.count, 2) + le(extra.count, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4)
      tail += le(0xffff_ffff, 4) + name + extra
      let directorySize = tail.count
      let record = directoryAt + directorySize
      tail += le(0x0606_4b50, 4) + le(44, 8) + le(45, 2) + le(45, 2) + le(0, 4) + le(0, 4)
      tail += le(1, 8) + le(1, 8) + le(directorySize, 8) + le(directoryAt, 8)
      tail += le(0x0706_4b50, 4) + le(0, 4) + le(record, 8) + le(1, 4)
      tail += le(0x0605_4b50, 4) + le(0, 2) + le(0, 2) + le(0xffff, 2) + le(0xffff, 2)
      tail += le(0xffff_ffff, 4) + le(0xffff_ffff, 4) + le(0, 2)
      let size = directoryAt + tail.count
      return try RestoreImageMember.locate("141-9-9.dmg.aea", archiveSize: size) { offset, count in
        Data(
          (offset..<(offset + count)).map { at -> UInt8 in
            if at >= header, at < directoryAt { return local[at - header] }
            if at >= directoryAt { return tail[at - directoryAt] }
            return 0
          })
      }
    }
    let far = 5 << 30
    expect(
      (try? sparse(header: far, zip64: true))
        == RestoreImageMember(
          name: "141-9-9.dmg.aea", offset: far + 30 + 15, size: 11,
          crc32: crc32([UInt8]("AEA1 sparse".utf8))), "member past 4 GiB")
    expect(
      (try? sparse(header: 0xffff_ffff, zip64: true))?.offset == 0xffff_ffff + 45,
      "member at 0xffffffff, offset in the ZIP64 field")
    expectThrows("member at 0xffffffff, no ZIP64 field", .invalidArchive) {
      _ = try sparse(header: 0xffff_ffff, zip64: false)
    }

    // A source that returns fewer bytes than asked for.
    expectThrows("short read", .shortRead) {
      _ = try RestoreImageMember.locate(b.name, archiveSize: bytes.count) { offset, count in
        Data(bytes[offset..<(offset + count - 1)])
      }
    }
    expectThrows("archive smaller than an end record", .invalidArchive) {
      _ = try RestoreImageMember.locate(b.name, archiveSize: 21) { _, _ in Data() }
    }

    if failures > 0 { exit(1) }
    print("restore-image-member: all checks passed")
  }
}
