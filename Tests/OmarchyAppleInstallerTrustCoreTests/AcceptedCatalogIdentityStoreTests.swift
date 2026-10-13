#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class AcceptedCatalogIdentityStoreTests: XCTestCase {
    func testMissingStateThenAtomicRoundTrip() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      let identity = try catalogIdentity(sequence: 8, digit: "a")

      XCTAssertNil(try store.load())
      try store.store(identity)

      XCTAssertEqual(try store.load(), identity)
      let state = directory.appendingPathComponent(
        AcceptedCatalogIdentityStore.fileName(for: .stable)
      )
      let permissions = try XCTUnwrap(
        try FileManager.default.attributesOfItem(atPath: state.path)[
          .posixPermissions
        ] as? NSNumber
      )
      XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testChannelsKeepIndependentSequences() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stable = AcceptedCatalogIdentityStore(
        directory: directory,
        channel: .stable
      )
      let rc = AcceptedCatalogIdentityStore(directory: directory, channel: .rc)

      try rc.store(try catalogIdentity(sequence: 90, digit: "b"))
      // Stable is far behind rc, which must not read as a rollback.
      try stable.store(try catalogIdentity(sequence: 10, digit: "a"))

      XCTAssertEqual(try stable.load()?.sequence, 10)
      XCTAssertEqual(try rc.load()?.sequence, 90)
    }

    func testMXMacFloorsAreNeitherReadNorRemoved() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      // The MX Mac installer shares this workspace; its stable floor is far
      // ahead of a new stream's first catalog.
      for name in AcceptedCatalogIdentityStore.mxMacFileNames {
        try writeMXMacState(
          try catalogIdentity(sequence: 1_790_210_231, digit: "c"), named: name, in: directory)
      }

      for channel in ReleaseChannel.allCases {
        let store = AcceptedCatalogIdentityStore(directory: directory, channel: channel)
        XCTAssertNil(try store.load(), channel.rawValue)
        try store.store(try catalogIdentity(sequence: 7, digit: "d"))
        XCTAssertEqual(try store.load()?.sequence, 7)
      }
      for name in AcceptedCatalogIdentityStore.mxMacFileNames {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1790210231"), name)
      }
    }

    func testStateFilesAreNamedByStreamAndChannel() {
      let names = ReleaseChannel.allCases.map(AcceptedCatalogIdentityStore.fileName(for:))
      XCTAssertEqual(Set(names).count, ReleaseChannel.allCases.count)
      for name in names {
        XCTAssertTrue(name.hasPrefix("accepted-catalog-omarchy-mac-"), name)
        XCTAssertFalse(AcceptedCatalogIdentityStore.mxMacFileNames.contains(name), name)
      }
    }

    func testRollbackSequenceIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      try store.store(try catalogIdentity(sequence: 9, digit: "a"))

      XCTAssertThrowsError(
        try store.store(try catalogIdentity(sequence: 8, digit: "b"))
      ) {
        XCTAssertEqual(
          $0 as? SupportCatalogSequenceError,
          .rollback(stored: 9, candidate: 8)
        )
      }
    }

    func testSequenceReuseWithDifferentPayloadIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = AcceptedCatalogIdentityStore(directory: directory, channel: .stable)
      try store.store(try catalogIdentity(sequence: 9, digit: "a"))

      XCTAssertThrowsError(
        try store.store(try catalogIdentity(sequence: 9, digit: "b"))
      ) {
        XCTAssertEqual(
          $0 as? SupportCatalogSequenceError,
          .sequenceReuse(9)
        )
      }
    }

    func testSymlinkedStateIsRejected() throws {
      let directory = try privateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let external = directory.deletingLastPathComponent()
        .appendingPathComponent(
          "omarchy-catalog-external-\(UUID().uuidString.lowercased())"
        )
      defer { try? FileManager.default.removeItem(at: external) }
      try Data("{}".utf8).write(
        to: external,
        options: .withoutOverwriting
      )
      try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent(
          AcceptedCatalogIdentityStore.fileName(for: .stable)
        ),
        withDestinationURL: external
      )

      XCTAssertThrowsError(
        try AcceptedCatalogIdentityStore(directory: directory, channel: .stable).load()
      ) {
        XCTAssertEqual(
          $0 as? AcceptedCatalogIdentityStoreError,
          .unsafeState
        )
      }
    }

    private func writeMXMacState(
      _ identity: AcceptedCatalogIdentity,
      named name: String,
      in directory: URL
    ) throws {
      let document = """
        {"payload_digest":"\(identity.payloadDigest)","schema_version":1,"sequence":\(identity.sequence)}
        """
      let url = directory.appendingPathComponent(name)
      try Data(document.utf8).write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func catalogIdentity(
      sequence: UInt64,
      digit: Character
    ) throws -> AcceptedCatalogIdentity {
      try AcceptedCatalogIdentity(
        sequence: sequence,
        payloadDigest: "sha256:" + String(repeating: digit, count: 64)
      )
    }

    private func privateDirectory() throws -> URL {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "omarchy-catalog-store-\(UUID().uuidString.lowercased())",
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return directory
    }
  }
#endif
