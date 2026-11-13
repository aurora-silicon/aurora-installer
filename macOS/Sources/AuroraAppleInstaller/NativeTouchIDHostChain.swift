#if os(macOS)
  import Darwin
  import Foundation

  /// The host certificate chain a Magic Keyboard with Touch ID needs before
  /// it pairs: this Mac's attestation leaf and its intermediate, as two
  /// concatenated DER certificates. The leaf is bound to this Mac's Secure
  /// Enclave, so it is per-machine data like the ambient light calibration.
  ///
  /// macOS keeps a copy on the Hardware volume. Neither the file nor its
  /// container format is fixed (raw DER, PEM, or bytes or base64 inside a
  /// property list), so the scan goes by content. The kernel checks the leaf
  /// against the enclave before it uses the chain, so only the structure is
  /// checked here, and never the validity dates.
  enum NativeTouchIDHostChain {
    static let firmwareName = "apple/stac-host-chain.der"
    static let leafIssuer = "Basic Attestation User Sub CA2"
    static let intermediateIssuer = "Basic Attestation User Root CA"
    static let leafUnit = "BAA Certification"
    static let organization = "Apple Inc."
    static let maximumCertificateBytes = 16 << 10

    enum Failure: Error, Equatable, CustomStringConvertible {
      /// Several different leaves, or several intermediates for the leaf.
      case ambiguous(Int)
      /// A leaf without an intermediate.
      case incomplete
      /// The scan reached its file count, total size or depth bound.
      case limit
      /// The bytes to publish are not exactly a leaf and its intermediate.
      case malformed

      var description: String {
        switch self {
        case .ambiguous(let count): "\(count) different host certificate chains"
        case .incomplete: "a host certificate without its intermediate"
        case .limit: "the Hardware volume scan reached its bounds"
        case .malformed: "not a host certificate chain"
        }
      }
    }

    struct Limits: Sendable {
      var fileBytes = 1 << 20
      var files = 20000
      var totalBytes = 128 << 20
      var depth = 16
    }

    enum Kind: Equatable { case leaf, intermediate }

    /// Accumulates the certificates found in each file. One file can hold
    /// both certificates, back to back or in separate records; the same
    /// bytes may appear in several files.
    struct Scanner {
      private(set) var leaves = Set<[UInt8]>()
      private(set) var intermediates = Set<[UInt8]>()
      private var paired = [[UInt8]: Set<[UInt8]>]()

      mutating func add(_ data: Data) {
        let found = NativeTouchIDHostChain.certificates(in: [UInt8](data))
        leaves.formUnion(found.leaves)
        intermediates.formUnion(found.intermediates)
        for (leaf, intermediate) in found.adjacent {
          paired[leaf, default: []].insert(intermediate)
        }
        if found.adjacent.isEmpty, found.leaves.count == 1, found.intermediates.count == 1 {
          paired[found.leaves.first!, default: []].insert(found.intermediates.first!)
        }
      }

      /// Exactly one leaf, and exactly one intermediate for it, or nothing.
      func result() throws -> Data? {
        guard let leaf = leaves.first else { return nil }
        guard leaves.count == 1 else { throw Failure.ambiguous(leaves.count) }
        let candidates = paired[leaf] ?? intermediates
        guard let intermediate = candidates.first else { throw Failure.incomplete }
        guard candidates.count == 1 else { throw Failure.ambiguous(candidates.count) }
        return Data(leaf + intermediate)
      }
    }

    struct Found {
      var leaves = Set<[UInt8]>()
      var intermediates = Set<[UInt8]>()
      var adjacent = [([UInt8], [UInt8])]()
    }

    /// Raw DER certificates, and certificates in base64 text (PEM, or a
    /// property list's `<data>`).
    static func certificates(in bytes: [UInt8]) -> Found {
      var found = Found()
      scanDER(bytes, into: &found)
      scanBase64(bytes, into: &found)
      return found
    }

    /// The structural check for bytes about to be published: exactly a leaf
    /// followed by its intermediate, nothing else.
    static func isChain(_ data: Data) -> Bool {
      let bytes = [UInt8](data)
      guard let leaf = certificate(bytes, at: 0, end: bytes.count), leaf.kind == .leaf,
        let intermediate = certificate(bytes, at: leaf.end, end: bytes.count),
        intermediate.kind == .intermediate, intermediate.end == bytes.count
      else { return false }
      return true
    }

    static func files(chain: Data?) throws -> [String: Data] {
      guard let chain else { return [:] }
      guard isChain(chain) else { throw Failure.malformed }
      return [firmwareName: chain]
    }

    /// Collection never stops an installation: without the chain only the
    /// Touch ID keyboard's pairing is missing. Each outcome is one log line
    /// that carries no certificate bytes.
    static func collect(_ source: () throws -> Data?) throws -> [String: Data] {
      do {
        let chain = try source()
        let result = try files(chain: chain)
        if let chain {
          InstallerLog.record(
            .progress, "Touch ID keyboard host certificate chain collected (\(chain.count) bytes)")
        } else {
          InstallerLog.record(
            .progress, "No Touch ID keyboard host certificate chain on this Mac's Hardware volume")
        }
        return result
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        InstallerLog.record(
          .progress, "Touch ID keyboard host certificate chain not collected: \(error)")
        return [:]
      }
    }

    /// Scans the Hardware volume. A missing volume is no chain.
    static func live() throws -> Data? {
      let scan = try scan(root: NativeSensorInputCollector.hardwareVolume, limits: Limits())
      if scan.unreadable > 0 {
        InstallerLog.record(
          .progress,
          "Touch ID keyboard host certificate scan skipped \(scan.unreadable) unreadable entries")
      }
      return try scan.scanner.result()
    }

    /// A bounded walk of one volume: symlinks, other mounts, special files
    /// and files over the size bound are skipped; unreadable entries are
    /// counted and skipped.
    static func scan(root: URL, limits: Limits) throws -> (scanner: Scanner, unreadable: Int) {
      var scanner = Scanner()
      var rootInfo = stat()
      guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
        return (scanner, 0)
      }
      var entries = 0
      var total = 0
      var unreadable = 0
      func walk(_ directory: String, depth: Int) throws {
        guard depth <= limits.depth else { throw Failure.limit }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
          unreadable += 1
          return
        }
        guard let stream = fdopendir(descriptor) else {
          close(descriptor)
          unreadable += 1
          return
        }
        var names = [String]()
        while let entry = readdir(stream) {
          let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
              String(cString: $0)
            }
          }
          if name == "." || name == ".." { continue }
          entries += 1
          guard entries <= limits.files else {
            closedir(stream)
            throw Failure.limit
          }
          names.append(name)
        }
        closedir(stream)
        for name in names.sorted() {
          try Task.checkCancellation()
          let path = directory + "/" + name
          var info = stat()
          guard lstat(path, &info) == 0 else {
            unreadable += 1
            continue
          }
          guard info.st_dev == rootInfo.st_dev else { continue }
          switch info.st_mode & S_IFMT {
          case S_IFDIR:
            try walk(path, depth: depth + 1)
          case S_IFREG:
            guard info.st_size > 0, info.st_size <= limits.fileBytes else { continue }
            guard let data = read(path, device: rootInfo.st_dev, maximum: limits.fileBytes) else {
              unreadable += 1
              continue
            }
            guard data.count <= limits.totalBytes - total else { throw Failure.limit }
            total += data.count
            scanner.add(data)
          default:
            continue
          }
        }
      }
      try walk(root.path, depth: 0)
      return (scanner, unreadable)
    }

    private static func read(_ path: String, device: dev_t, maximum: Int) -> Data? {
      let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { return nil }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_dev == device, info.st_size <= maximum
      else { return nil }
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while result.count <= maximum {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { return nil }
        if count == 0 { break }
        result.append(contentsOf: buffer[0..<count])
      }
      return result.count <= maximum ? result : nil
    }

    // MARK: DER

    struct Element {
      let tag: UInt8
      let start: Int
      let end: Int
    }

    /// One definite, minimally encoded TLV inside `end`.
    static func element(_ b: [UInt8], at offset: Int, end: Int) -> Element? {
      guard offset >= 0, offset + 2 <= end else { return nil }
      let tag = b[offset]
      guard tag & 0x1f != 0x1f else { return nil }
      let first = Int(b[offset + 1])
      var start = offset + 2
      var length = first
      if first >= 0x80 {
        let count = first & 0x7f
        guard count >= 1, count <= 3, start + count <= end, b[start] != 0 else { return nil }
        length = 0
        for index in 0..<count { length = length << 8 | Int(b[start + index]) }
        guard length >= 0x80 else { return nil }
        start += count
      }
      guard length <= end - start else { return nil }
      return Element(tag: tag, start: start, end: start + length)
    }

    /// The children of a constructed element; they must fill it exactly.
    static func children(_ b: [UInt8], of parent: Element, maximum: Int = 64) -> [Element]? {
      var result = [Element]()
      var offset = parent.start
      while offset < parent.end {
        guard result.count < maximum, let child = element(b, at: offset, end: parent.end) else {
          return nil
        }
        result.append(child)
        offset = child.end
      }
      return result
    }

    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let organizationName: [UInt8] = [0x55, 0x04, 0x0a]
    static let unitName: [UInt8] = [0x55, 0x04, 0x0b]

    /// The attributes of an X.501 Name, in order. A value that is not a
    /// UTF8, printable, IA5 or teletex string is kept as nil.
    static func name(_ b: [UInt8], _ element: Element) -> [([UInt8], String?)]? {
      guard element.tag == 0x30, let sets = children(b, of: element) else { return nil }
      var result = [([UInt8], String?)]()
      for set in sets {
        guard set.tag == 0x31, let attributes = children(b, of: set) else { return nil }
        for attribute in attributes {
          guard attribute.tag == 0x30, let parts = children(b, of: attribute), parts.count == 2,
            parts[0].tag == 0x06
          else { return nil }
          let oid = Array(b[parts[0].start..<parts[0].end])
          var value: String?
          if [0x0c, 0x13, 0x16, 0x14].contains(parts[1].tag) {
            value = String(bytes: b[parts[1].start..<parts[1].end], encoding: .utf8)
          }
          result.append((oid, value))
        }
      }
      return result
    }

    /// The single value of an attribute, or nil when it is absent or repeated.
    static func single(_ attributes: [([UInt8], String?)], _ oid: [UInt8]) -> String? {
      let values = attributes.filter { $0.0 == oid }
      guard values.count == 1 else { return nil }
      return values[0].1
    }

    static func isLeafName(_ value: String) -> Bool {
      value.utf8.count == 64
        && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A certificate at `offset` that is a host leaf or its intermediate.
    static func certificate(_ b: [UInt8], at offset: Int, end: Int) -> (kind: Kind, end: Int)? {
      guard let outer = element(b, at: offset, end: end), outer.tag == 0x30,
        outer.end - offset <= maximumCertificateBytes,
        let parts = children(b, of: outer, maximum: 3), parts.count == 3,
        parts[0].tag == 0x30, parts[1].tag == 0x30, parts[2].tag == 0x03,
        var fields = children(b, of: parts[0], maximum: 10)
      else { return nil }
      if fields.first?.tag == 0xa0 { fields.removeFirst() }
      guard fields.count >= 6,
        fields[0...5].map(\.tag) == [0x02, 0x30, 0x30, 0x30, 0x30, 0x30]
      else { return nil }
      var previous: UInt8 = 0xa0
      for field in fields.dropFirst(6) {
        guard field.tag > previous, field.tag <= 0xa3 else { return nil }
        previous = field.tag
      }
      guard let issuer = name(b, fields[2]), let subject = name(b, fields[4]),
        let issuerName = single(issuer, commonName),
        let subjectName = single(subject, commonName)
      else { return nil }
      if subjectName == leafIssuer, issuerName == intermediateIssuer {
        return (.intermediate, outer.end)
      }
      if issuerName == leafIssuer, isLeafName(subjectName),
        single(subject, unitName) == leafUnit, single(subject, organizationName) == organization
      {
        return (.leaf, outer.end)
      }
      return nil
    }

    /// Every `30 82` that starts a matching certificate. A leaf followed
    /// directly by an intermediate is recorded as a pair.
    static func scanDER(_ b: [UInt8], into found: inout Found) {
      var offset = 0
      var lastLeaf: (der: [UInt8], end: Int)?
      b.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        while offset + 4 <= buffer.count {
          guard let hit = memchr(base + offset, 0x30, buffer.count - offset - 3) else { break }
          let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
          offset = start + 1
          guard buffer[start + 1] == 0x82, let match = certificate(b, at: start, end: b.count)
          else { continue }
          let der = Array(b[start..<match.end])
          switch match.kind {
          case .leaf:
            found.leaves.insert(der)
            lastLeaf = (der, match.end)
          case .intermediate:
            found.intermediates.insert(der)
            if let leaf = lastLeaf, leaf.end == start { found.adjacent.append((leaf.der, der)) }
          }
          offset = match.end
        }
      }
    }

    static func isBase64(_ c: UInt8) -> Bool {
      (0x41...0x5a).contains(c) || (0x61...0x7a).contains(c) || (0x30...0x39).contains(c)
        || c == 0x2b || c == 0x2f
    }

    /// Base64 runs (whitespace allowed inside) that start with `MII`, the
    /// encoding of a DER SEQUENCE with a two-byte length.
    static func scanBase64(_ b: [UInt8], into found: inout Found) {
      let marker: [UInt8] = [0x4d, 0x49, 0x49]
      var offset = 0
      while offset + 3 <= b.count {
        let hit: Int? = b.withUnsafeBufferPointer { buffer in
          marker.withUnsafeBufferPointer { needle in
            guard
              let pointer = memmem(
                buffer.baseAddress! + offset, buffer.count - offset, needle.baseAddress!, 3)
            else { return nil }
            return buffer.baseAddress!.distance(to: pointer.assumingMemoryBound(to: UInt8.self))
          }
        }
        guard let start = hit else { break }
        var text = [UInt8]()
        var index = start
        while index < b.count, text.count < 1 << 16 {
          let c = b[index]
          if isBase64(c) {
            text.append(c)
          } else if c != 0x20, c != 0x09, c != 0x0a, c != 0x0d {
            break
          }
          index += 1
        }
        var padding = 0
        while index < b.count, b[index] == 0x3d, padding < 2 {
          padding += 1
          index += 1
        }
        var encoded = text
        if (text.count + padding) % 4 == 0 {
          encoded += [UInt8](repeating: 0x3d, count: padding)
        } else {
          encoded.removeLast(text.count % 4)
        }
        if let decoded = Data(base64Encoded: Data(encoded)) {
          scanDER([UInt8](decoded), into: &found)
        }
        offset = max(index, start + 3)
      }
    }
  }
#endif
