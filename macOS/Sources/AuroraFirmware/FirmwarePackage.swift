// SPDX-License-Identifier: MIT
import Foundation
import zlib

public struct FirmwarePackageInput: Sendable {
  public let name: String
  public let bytes: Data

  public init(name: String, bytes: Data) {
    self.name = name
    self.bytes = bytes
  }
}

public struct FirmwarePackageArchives: Sendable {
  public let tar: Data
  public let cpio: Data
  public let manifest: Data
}

/// Native serialization of the vendor firmware interchange formats. Callers
/// must admit source identity and per-machine calibration before packaging.
public enum FirmwarePackageBuilder {
  public static func build(_ inputs: [FirmwarePackageInput]) throws -> FirmwarePackageArchives {
    try require(!inputs.isEmpty && inputs.count <= 4096, "Invalid firmware package file count.")
    var names = Set<String>()
    var total = 0
    for input in inputs {
      try require(
        safeRelative(input.name) && input.name != ".vendorfw.manifest"
          && !input.name.hasPrefix(".vendorfw.manifest/")
          && input.name.utf8.count <= 255
          && input.name.utf8.allSatisfy { (33...126).contains($0) }
          && !names.contains(input.name)
          && !names.contains { input.name.hasPrefix($0 + "/") || $0.hasPrefix(input.name + "/") },
        "Invalid or conflicting firmware package path.")
      try require(input.bytes.count <= maxFileBytes, "Firmware package file exceeds its budget.")
      total += input.bytes.count
      try require(total <= 256 * 1024 * 1024, "Firmware package exceeds its memory budget.")
      names.insert(input.name)
    }
    var tar = Data()
    var cpio = NewcArchive()
    var first: [String: String] = [:]
    var manifest = ""
    for input in inputs {
      let digest = input.bytes.sha256
      // USTAR hardlink names have no prefix field. A long target is emitted
      // as another regular file, preserving contents without a PAX dependency.
      let target = first[digest].flatMap { $0.utf8.count <= 100 ? $0 : nil }
      if let target {
        manifest += "LINK \(input.name) \(target)\n"
      } else {
        manifest += "FILE \(input.name) SHA256 \(digest)\n"
        first[digest] = input.name
      }
      try appendTar(&tar, name: input.name, bytes: input.bytes, target: target)
      cpio.add(
        name: "vendorfw/" + input.name, bytes: target == nil ? input.bytes : Data(),
        target: target.map { "vendorfw/" + $0 })
    }
    let manifestBytes = Data(manifest.utf8)
    cpio.add(name: "vendorfw/.vendorfw.manifest", bytes: manifestBytes)
    // Two end-of-archive blocks, padded to the interchange record size.
    tar.append(Data(repeating: 0, count: 1024))
    pad(&tar, alignment: 10240)
    return FirmwarePackageArchives(tar: tar, cpio: cpio.finish(), manifest: manifestBytes)
  }

  /// The fallback is a separate raw-input archive, with stable metadata and
  /// gzip header so interruption/retry reproduces the same published bytes.
  public static func fallback(
    _ inputs: [FirmwarePackageInput], symbolicLinks: [String: String]
  ) throws -> Data {
    try require(
      !inputs.isEmpty && inputs.count + symbolicLinks.count <= 20000,
      "Invalid fallback file count.")
    var names = Set<String>()
    var total = 0
    for input in inputs {
      try require(
        safeRelative(input.name) && input.name.utf8.count <= 255,
        "Invalid fallback input name.")
      try require(
        names.insert(input.name).inserted && input.bytes.count <= maxFileBytes,
        "Conflicting fallback input.")
      total += input.bytes.count
      try require(total <= 256 << 20, "Fallback inputs exceed their budget.")
    }
    for (name, target) in symbolicLinks {
      try require(
        safeRelative(name) && name.utf8.count <= 255 && names.insert(name).inserted
          && name.split(separator: "/").count >= 2
          && target.hasPrefix("../") && safeRelative(String(target.dropFirst(3)))
          && target.utf8.count <= 100, "Invalid fallback alias.")
      let components = name.split(separator: "/").dropLast().dropLast().map(String.init)
      let resolved = (components + [String(target.dropFirst(3))]).joined(separator: "/")
      try require(inputs.contains(where: { $0.name == resolved }), "Missing fallback alias target.")
    }
    let sorted = names.sorted()
    for name in sorted {
      var parent = ""
      for part in name.split(separator: "/").dropLast() {
        parent += (parent.isEmpty ? "" : "/") + part
        try require(!names.contains(parent), "Conflicting fallback paths.")
      }
    }
    var tar = Data()
    let files = Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, $0.bytes) })
    for name in sorted {
      try Task.checkCancellation()
      try appendTar(
        &tar, name: name, bytes: files[name] ?? Data(),
        target: symbolicLinks[name], symbolic: symbolicLinks[name] != nil)
    }
    tar.append(Data(repeating: 0, count: 1024))
    pad(&tar, alignment: 10240)
    var stream = z_stream()
    let initialized = deflateInit2_(
      &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
      ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    try require(initialized == Z_OK, "Cannot initialize fallback compression.")
    defer { deflateEnd(&stream) }
    return try tar.withUnsafeBytes { source in
      stream.next_in = UnsafeMutablePointer(
        mutating: source.bindMemory(to: UInt8.self).baseAddress!)
      stream.avail_in = uInt(tar.count)
      var compressed = Data()
      while true {
        try Task.checkCancellation()
        var block = Data(count: 64 << 10)
        let status = block.withUnsafeMutableBytes { output in
          stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
          stream.avail_out = uInt(output.count)
          return deflate(&stream, Z_FINISH)
        }
        try require(status == Z_OK || status == Z_STREAM_END, "Fallback compression failed.")
        block.count -= Int(stream.avail_out)
        try require(
          block.count <= (256 << 20) - compressed.count,
          "Compressed fallback exceeds its budget.")
        compressed.append(block)
        if status == Z_STREAM_END { return compressed }
      }
    }
  }

  private static func pad(_ bytes: inout Data, alignment: Int) {
    bytes.append(Data(repeating: 0, count: (alignment - bytes.count % alignment) % alignment))
  }

  private static func appendTar(
    _ archive: inout Data, name: String, bytes: Data, target: String?, symbolic: Bool = false
  )
    throws
  {
    var header = Data(repeating: 0, count: 512)
    func field(_ offset: Int, _ width: Int, _ text: String) throws {
      let value = Data(text.utf8)
      try require(value.count <= width, "Firmware tar header exceeds its field.")
      header.replaceSubrange(offset..<(offset + value.count), with: value)
    }
    func octal(_ offset: Int, _ width: Int, _ value: Int) throws {
      let text = String(value, radix: 8)
      try require(text.count < width, "Firmware tar integer exceeds its field.")
      try field(offset, width, String(repeating: "0", count: width - text.count - 1) + text + "\0")
    }
    if name.utf8.count <= 100 {
      try field(0, 100, name)
    } else {
      guard
        let split = name.indices.reversed().first(where: {
          name[$0] == "/" && name[..<$0].utf8.count <= 155
            && name[name.index(after: $0)...].utf8.count <= 100
        })
      else { throw RestoreFailure("Firmware path cannot be represented by USTAR.") }
      try field(0, 100, String(name[name.index(after: split)...]))
      try field(345, 155, String(name[..<split]))
    }
    try octal(100, 8, 0o644)
    try octal(108, 8, 0)
    try octal(116, 8, 0)
    try octal(124, 12, target == nil ? bytes.count : 0)
    try octal(136, 12, 0)
    try field(148, 8, "        ")
    try field(156, 1, target == nil ? "0" : symbolic ? "2" : "1")
    if let target { try field(157, 100, target) }
    try field(257, 8, "ustar\0" + "00")
    let checksum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
    try require(checksum.count <= 6, "Firmware tar checksum exceeds its field.")
    try field(148, 8, String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ")
    archive.append(header)
    if target == nil { archive.append(bytes) }
    pad(&archive, alignment: 512)
  }

  private struct NewcArchive {
    private struct Entry {
      let name: String
      let inode: Int
      let mode: Int
      let bytes: Data
    }
    private var entries: [Entry] = []
    private var inodes: [String: Int] = [:]
    private var links: [Int: Int] = [:]
    private var nextInode = 1

    mutating func add(name: String, bytes: Data, target: String? = nil) {
      let parts = name.split(separator: "/")
      var path = ""
      for part in parts.dropLast() {
        path += (path.isEmpty ? "" : "/") + String(part)
        if inodes[path] == nil { append(path, mode: 0o040755, bytes: Data()) }
      }
      append(name, mode: 0o100644, bytes: bytes, target: target)
    }

    private mutating func append(_ name: String, mode: Int, bytes: Data, target: String? = nil) {
      let inode: Int
      if let target, let existing = inodes[target] {
        inode = existing
      } else {
        inode = nextInode
        nextInode += 1
      }
      links[inode, default: 0] += 1
      inodes[name] = inode
      entries.append(Entry(name: name, inode: inode, mode: mode, bytes: bytes))
    }

    mutating func finish() -> Data {
      append("TRAILER!!!", mode: 0o100644, bytes: Data())
      var archive = Data()
      for entry in entries {
        FirmwarePackageBuilder.pad(&archive, alignment: 4)
        archive.append(Data("070701".utf8))
        let fields = [
          entry.inode, entry.mode, 0, 0, links[entry.inode]!, 0,
          entry.bytes.count, 0, 0, 0, 0, entry.name.utf8.count + 1, 0,
        ]
        for field in fields { archive.append(Data(String(format: "%08x", field).utf8)) }
        archive.append(Data(entry.name.utf8))
        archive.append(0)
        FirmwarePackageBuilder.pad(&archive, alignment: 4)
        archive.append(entry.bytes)
      }
      return archive
    }
  }
}
