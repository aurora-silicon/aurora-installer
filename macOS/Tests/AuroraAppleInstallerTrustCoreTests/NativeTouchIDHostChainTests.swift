#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// Synthetic certificates with the host chain's subject and issuer names.
  /// They are well-formed DER but unsigned: the installer checks structure
  /// only. No Apple-issued certificate is used by these tests.
  enum SyntheticHostChain {
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let organization: [UInt8] = [0x55, 0x04, 0x0a]
    static let unit: [UInt8] = [0x55, 0x04, 0x0b]

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
      let count = content.count
      if count < 0x80 { return [tag, UInt8(count)] + content }
      if count < 0x100 { return [tag, 0x81, UInt8(count)] + content }
      return [tag, 0x82, UInt8(count >> 8), UInt8(count & 0xff)] + content
    }

    static func name(_ attributes: [([UInt8], String)]) -> [UInt8] {
      tlv(
        0x30,
        attributes.flatMap {
          tlv(0x31, tlv(0x30, tlv(0x06, $0.0) + tlv(0x0c, Array($0.1.utf8))))
        })
    }

    static func certificate(
      subject: [([UInt8], String)], issuer: [([UInt8], String)], serial: UInt8
    ) -> [UInt8] {
      let algorithm = tlv(0x30, tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
      let validity = tlv(
        0x30, tlv(0x17, Array("260101000000Z".utf8)) + tlv(0x17, Array("260102000000Z".utf8)))
      let key = tlv(
        0x30,
        tlv(
          0x30,
          tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
            + tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]))
          + tlv(0x03, [0x00, 0x04] + [UInt8](repeating: serial, count: 64)))
      let tbs = tlv(
        0x30,
        tlv(0xa0, tlv(0x02, [0x02])) + tlv(0x02, [0x01, serial]) + algorithm + name(issuer)
          + validity + name(subject) + key + tlv(0xa3, tlv(0x30, [])))
      return tlv(0x30, tbs + algorithm + tlv(0x03, [0x00] + [UInt8](repeating: 0x5a, count: 70)))
    }

    static func leaf(
      _ hex: String = String(repeating: "0123456789abcdef", count: 4),
      unit unitValue: String = "BAA Certification",
      issuer issuerName: String = "Basic Attestation User Sub CA2", serial: UInt8 = 1
    ) -> [UInt8] {
      certificate(
        subject: [(commonName, hex), (unit, unitValue), (organization, "Apple Inc.")],
        issuer: [(commonName, issuerName), (organization, "Apple Inc.")], serial: serial)
    }

    static func intermediate(serial: UInt8 = 2) -> [UInt8] {
      certificate(
        subject: [(commonName, "Basic Attestation User Sub CA2"), (organization, "Apple Inc.")],
        issuer: [(commonName, "Basic Attestation User Root CA"), (organization, "Apple Inc.")],
        serial: serial)
    }

    static func chain(_ leaf: [UInt8] = leaf()) -> [UInt8] { leaf + intermediate() }

    static func pem(_ der: [UInt8]) -> String {
      let body = Data(der).base64EncodedString(options: [
        .lineLength64Characters, .endLineWithLineFeed,
      ])
      return "-----BEGIN CERTIFICATE-----\n" + body + "\n-----END CERTIFICATE-----\n"
    }
  }

  final class NativeTouchIDHostChainTests: XCTestCase {
    typealias Chain = NativeTouchIDHostChain

    private func result(_ blobs: [Data]) throws -> Data? {
      var scanner = Chain.Scanner()
      for blob in blobs { scanner.add(blob) }
      return try scanner.result()
    }

    func testSyntheticCertificatesUseTwoByteLengths() {
      for der in [SyntheticHostChain.leaf(), SyntheticHostChain.intermediate()] {
        XCTAssertEqual(Array(der.prefix(2)), [0x30, 0x82])
      }
      XCTAssertEqual(
        Chain.certificate(
          SyntheticHostChain.leaf(), at: 0, end: SyntheticHostChain.leaf().count)?.kind, .leaf)
    }

    func testRawDERInsideOtherBytesIsFound() throws {
      let chain = SyntheticHostChain.chain()
      let blob = Data([0x30, 0x82, 0xff, 0xff, 0x00] + chain + [0x30, 0x82, 0x01])
      XCTAssertEqual(try result([blob]), Data(chain))
    }

    func testPEMAndXMLPlistBase64AreFound() throws {
      let leaf = SyntheticHostChain.leaf()
      let intermediate = SyntheticHostChain.intermediate()
      let pem = SyntheticHostChain.pem(leaf) + SyntheticHostChain.pem(intermediate)
      XCTAssertEqual(try result([Data(pem.utf8)]), Data(leaf + intermediate))

      let plist = try PropertyListSerialization.data(
        fromPropertyList: ["HostChain": Data(leaf + intermediate), "Other": "text"],
        format: .xml, options: 0)
      XCTAssertTrue(String(decoding: plist, as: UTF8.self).contains("MII"))
      XCTAssertEqual(try result([plist]), Data(leaf + intermediate))
    }

    func testBinaryPlistWithSeparateRecordsIsPaired() throws {
      let plist = try PropertyListSerialization.data(
        fromPropertyList: [
          "certificates": [
            Data(SyntheticHostChain.intermediate()), Data(SyntheticHostChain.leaf()),
          ]
        ], format: .binary, options: 0)
      XCTAssertEqual(try result([plist]), Data(SyntheticHostChain.chain()))
    }

    func testCopiesOfOneChainAreOneChain() throws {
      let chain = Data(SyntheticHostChain.chain())
      let base64 = Data(chain.base64EncodedString().utf8)
      XCTAssertEqual(try result([chain, base64, chain + chain]), chain)
    }

    func testTwoDifferentChainsAreAmbiguous() {
      let other = SyntheticHostChain.leaf(String(repeating: "f", count: 64), serial: 9)
      XCTAssertThrowsError(
        try result([Data(SyntheticHostChain.chain()), Data(SyntheticHostChain.chain(other))])
      ) { XCTAssertEqual($0 as? Chain.Failure, .ambiguous(2)) }
    }

    func testAbsenceAndIncompleteChains() throws {
      XCTAssertNil(try result([]))
      XCTAssertNil(try result([Data("no certificates here".utf8)]))
      XCTAssertNil(try result([Data(SyntheticHostChain.intermediate())]))
      XCTAssertThrowsError(try result([Data(SyntheticHostChain.leaf())])) {
        XCTAssertEqual($0 as? Chain.Failure, .incomplete)
      }
      // A leaf alone in one file still pairs with the only intermediate.
      XCTAssertEqual(
        try result([Data(SyntheticHostChain.leaf()), Data(SyntheticHostChain.intermediate())]),
        Data(SyntheticHostChain.chain()))
    }

    func testOtherCertificatesAreIgnored() throws {
      for leaf in [
        SyntheticHostChain.leaf(String(repeating: "A", count: 64)),
        SyntheticHostChain.leaf(String(repeating: "a", count: 63)),
        SyntheticHostChain.leaf(unit: "Other Certification"),
        SyntheticHostChain.leaf(issuer: "Basic Attestation User Sub CA1"),
      ] {
        XCTAssertNil(try result([Data(leaf)]))
      }
    }

    func testMalformedLengthsAreRejectedWithoutCrashing() throws {
      var chain = SyntheticHostChain.chain()
      XCTAssertNil(try result([Data(chain.dropLast(chain.count - 200))]))
      // A non-minimal outer length.
      let leaf = SyntheticHostChain.leaf()
      let padded = [0x30, 0x83, 0x00] + leaf.dropFirst(2)
      XCTAssertNil(Chain.certificate(padded, at: 0, end: padded.count))
      // An inner length past the outer element.
      chain[6] = 0xff
      XCTAssertNil(Chain.certificate(chain, at: 0, end: chain.count))
      var generator = SystemRandomNumberGenerator()
      for _ in 0..<64 {
        var noise = SyntheticHostChain.chain()
        for _ in 0..<8 {
          noise[Int.random(in: 0..<noise.count, using: &generator)] = UInt8.random(
            in: 0...255, using: &generator)
        }
        var scanner = Chain.Scanner()
        scanner.add(Data(noise))
        _ = try? scanner.result()
      }
    }

    func testPublicationNeedsExactlyLeafThenIntermediate() throws {
      let chain = Data(SyntheticHostChain.chain())
      XCTAssertEqual(try Chain.files(chain: nil), [:])
      XCTAssertEqual(try Chain.files(chain: chain), ["apple/stac-host-chain.der": chain])
      for bad in [
        Data(SyntheticHostChain.intermediate() + SyntheticHostChain.leaf()),
        Data(SyntheticHostChain.leaf()), chain + Data([0]),
      ] {
        XCTAssertThrowsError(try Chain.files(chain: bad)) {
          XCTAssertEqual($0 as? Chain.Failure, .malformed)
        }
      }
    }

    func testCollectionFailureDoesNotStopTheInstallation() throws {
      XCTAssertEqual(try Chain.collect { throw Chain.Failure.ambiguous(2) }, [:])
      XCTAssertEqual(try Chain.collect { Data([1, 2, 3]) }, [:])
      XCTAssertEqual(try Chain.collect { nil }, [:])
      XCTAssertThrowsError(try Chain.collect { throw CancellationError() }) {
        XCTAssertTrue($0 is CancellationError)
      }
    }

    func testVolumeScanIsBoundedAndSkipsLinks() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "touchid-host-chain-" + UUID().uuidString)
      let outside = root.appendingPathComponent("outside")
      let volume = root.appendingPathComponent("volume")
      defer { try? FileManager.default.removeItem(at: root) }
      let nested = volume.appendingPathComponent("a/b/c")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let chain = Data(SyntheticHostChain.chain())
      try chain.write(to: nested.appendingPathComponent("record.der"))
      try Data(SyntheticHostChain.pem(SyntheticHostChain.leaf()).utf8).write(
        to: volume.appendingPathComponent("copy.pem"))
      // A different chain behind a symlink and in an oversized file.
      let other = Data(
        SyntheticHostChain.chain(SyntheticHostChain.leaf(String(repeating: "e", count: 64))))
      try other.write(to: outside.appendingPathComponent("other.der"))
      try FileManager.default.createSymbolicLink(
        at: volume.appendingPathComponent("link.der"),
        withDestinationURL: outside.appendingPathComponent("other.der"))
      try FileManager.default.createSymbolicLink(
        at: volume.appendingPathComponent("linkdir"), withDestinationURL: outside)
      try (other + Data(count: 1 << 20)).write(to: volume.appendingPathComponent("big.bin"))

      let scan = try Chain.scan(root: volume, limits: .init())
      XCTAssertEqual(try scan.scanner.result(), chain)
      XCTAssertEqual(scan.unreadable, 0)

      XCTAssertThrowsError(try Chain.scan(root: volume, limits: .init(files: 3))) {
        XCTAssertEqual($0 as? Chain.Failure, .limit)
      }
      XCTAssertThrowsError(try Chain.scan(root: volume, limits: .init(depth: 2))) {
        XCTAssertEqual($0 as? Chain.Failure, .limit)
      }
      XCTAssertThrowsError(try Chain.scan(root: volume, limits: .init(totalBytes: 100))) {
        XCTAssertEqual($0 as? Chain.Failure, .limit)
      }
      let missing = try Chain.scan(
        root: root.appendingPathComponent("missing"), limits: .init())
      XCTAssertNil(try missing.scanner.result())
    }
  }
#endif
