#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  private final class ImportedByteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record(_ bytes: Int) {
      lock.lock()
      defer { lock.unlock() }
      value = max(value, bytes)
    }
    var maximum: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  final class EngineHandoffPackageImporterTests: XCTestCase {
    func testNativePackageImportsAndReopensWithoutAnExecutionArchive() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }
      let importer = EngineHandoffPackageImporter()
      let imported = try importer.prepare(from: source, in: fixture.destination)
      XCTAssertEqual(
        try importer.executionPlan(imported, owner: geteuid()).engineDigest,
        NativeExecutionIdentity.digest)
      let reopened = try importer.reopenRetained(
        named: imported.packageURL.lastPathComponent, in: fixture.destination)
      XCTAssertEqual(reopened.installationIntent, .fresh)
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: imported.packageURL.path)
          .contains("engine.tar.gz"))
    }

    func testFreshReplacementAndReinstallIntentSurvivesRetainedRevalidation() throws {
      for intent in [ImportedInstallationIntent.fresh, .replace, .reinstall] {
        let fixture = try makeFixture(
          replace: intent == .replace, reinstall: intent == .reinstall)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        let importer = EngineHandoffPackageImporter()
        let imported = try importer.prepare(from: source, in: fixture.destination)
        XCTAssertEqual(imported.installationIntent, intent)
        let reopened = try importer.reopenRetained(
          named: imported.packageURL.lastPathComponent,
          in: fixture.destination)
        XCTAssertEqual(reopened.installationIntent, intent)
        if intent == .reinstall {
          XCTAssertThrowsError(try importer.executionPlan(imported, owner: geteuid()))
          let plan = try importer.preservedExecutionPlan(imported, owner: geteuid())
          XCTAssertEqual(plan.candidateKind, "reinstall")
          XCTAssertEqual(plan.requiredHumanSteps, ["authenticateMachineOwner"])
        }
      }
    }

    func testNewPackagesNamingTheRetiredEngineOrRepairAreRefused() throws {
      for repair in [false, true] {
        let fixture = try makeFixture(legacyEngine: true, repair: repair)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        XCTAssertThrowsError(
          try EngineHandoffPackageImporter().prepare(from: source, in: fixture.destination)
        ) {
          XCTAssertEqual($0 as? EngineHandoffImportError, .nativeEngineRequired)
        }
        XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
      }
    }

    func testOlderRetainedPackagesReopenSoTheirJobsContinueNatively() throws {
      // An older helper retained these with its engine archive. They are still
      // verified file by file; the archive itself is never run.
      for intent in [ImportedInstallationIntent.fresh, .repair] {
        let fixture = try makeFixture(legacyEngine: true, repair: intent == .repair)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let name = try retainAsOlderHelperWould(fixture)
        let importer = EngineHandoffPackageImporter()
        let reopened = try importer.reopenRetained(named: name, in: fixture.destination)
        XCTAssertEqual(reopened.installationIntent, intent)
        if intent == .fresh {
          XCTAssertEqual(
            try importer.executionPlan(reopened, owner: geteuid()).engineVersion,
            "v0.9.0-omarchy.2")
        }
        let engine = reopened.packageURL.appendingPathComponent("engine.tar.gz")
        XCTAssertEqual(chmod(engine.path, 0o600), 0)
        try Data("changed".utf8).write(to: engine)
        XCTAssertThrowsError(try importer.reopenRetained(named: name, in: fixture.destination))
      }
    }

    func testReinstallCannotBeRelabeledAsFreshInstallation() throws {
      let fixture = try makeFixture(reinstall: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let original = try String(contentsOf: fixture.requestURL, encoding: .utf8)
      let changed = original.replacingOccurrences(
        of: ImportedInstallationIntent.reinstallOperation, with: "install")
      try FileManager.default.removeItem(at: fixture.requestURL)
      try writePrivate(Data(changed.utf8), to: fixture.requestURL)
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }
      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(from: source, in: fixture.destination))
    }
    func testDecoderIsExecutableAndRetainedRetryRejectsChangedOrNonExecutableBytes() throws {
      for change in ["bytes", "execute-bit"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        let importer = EngineHandoffPackageImporter()
        let package = try importer.prepare(from: source, in: fixture.destination)
        let decoder = try XCTUnwrap(package.restoreImageURL)
        XCTAssertEqual(try mode(decoder), 0o500)
        let reopened = try importer.reopenRetained(
          named: package.packageURL.lastPathComponent, in: fixture.destination)
        XCTAssertEqual(reopened.restoreImageURL, decoder)
        XCTAssertEqual(chmod(decoder.path, 0o700), 0)
        if change == "bytes" {
          try Data("changed".utf8).write(to: decoder)
        } else {
          XCTAssertEqual(chmod(decoder.path, 0o400), 0)
        }
        XCTAssertThrowsError(
          try importer.reopenRetained(
            named: package.packageURL.lastPathComponent, in: fixture.destination))
      }
    }

    func testDecoderContainerRejectsMissingRenamedOversizedAndChangedArtifacts() throws {
      for change in ["missing", "renamed", "oversized", "changed"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestURL = fixture.source.appendingPathComponent("manifest.json")
        var document = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var decoder = try XCTUnwrap(document["restore_image"] as? [String: Any])
        if change == "missing" { document.removeValue(forKey: "restore_image") }
        if change == "renamed" {
          decoder["file_name"] = "another-decoder"
          document["restore_image"] = decoder
        }
        if change == "oversized" {
          decoder["size_bytes"] = RestoreImageHelper.maximumBytes + 1
          document["restore_image"] = decoder
        }
        try JSONSerialization.data(withJSONObject: document).write(
          to: manifestURL, options: .atomic)
        if change == "changed" {
          try Data("changed".utf8).write(
            to: fixture.source.appendingPathComponent(RestoreImageHelper.fileName), options: .atomic
          )
        }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        XCTAssertThrowsError(
          try EngineHandoffPackageImporter().prepare(from: source, in: fixture.destination))
        XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
      }
    }

    func testRetainedPackageIsRevalidatedInPlaceAndChangedPayloadIsRejected() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }
      let importer = EngineHandoffPackageImporter()
      let imported = try importer.prepare(from: source, in: fixture.destination)
      var before = stat()
      XCTAssertEqual(lstat(imported.payloadURL.path, &before), 0)
      let reopened = try importer.reopenRetained(
        named: imported.packageURL.lastPathComponent, in: fixture.destination)
      var after = stat()
      XCTAssertEqual(lstat(reopened.payloadURL.path, &after), 0)
      XCTAssertEqual(before.st_ino, after.st_ino)
      XCTAssertEqual(reopened.packageURL, imported.packageURL)
      XCTAssertEqual(try importedEntries(in: fixture.destination).count, 1)
      XCTAssertEqual(chmod(imported.payloadURL.path, 0o600), 0)
      var changed = fixture.payload
      changed[0] ^= 1
      try changed.write(to: imported.payloadURL)
      XCTAssertThrowsError(
        try importer.reopenRetained(
          named: imported.packageURL.lastPathComponent, in: fixture.destination)
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError, .digestMismatch(imported.payloadURL.lastPathComponent))
      }
    }

    func testRetainedPackageRejectsLinksAndCallerSuppliedPaths() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }
      let importer = EngineHandoffPackageImporter()
      let imported = try importer.prepare(from: source, in: fixture.destination)
      for name in [
        "../source", imported.packageURL.path, imported.packageURL.lastPathComponent + "/child",
      ] {
        XCTAssertThrowsError(try importer.reopenRetained(named: name, in: fixture.destination))
      }
      let alias = fixture.root.appendingPathComponent("hardlink")
      XCTAssertEqual(link(imported.payloadURL.path, alias.path), 0)
      XCTAssertThrowsError(
        try importer.reopenRetained(
          named: imported.packageURL.lastPathComponent, in: fixture.destination))
      XCTAssertEqual(unlink(alias.path), 0)
      try FileManager.default.removeItem(at: imported.metadataURL)
      try FileManager.default.createSymbolicLink(
        at: imported.metadataURL, withDestinationURL: fixture.metadataURL)
      XCTAssertThrowsError(
        try importer.reopenRetained(
          named: imported.packageURL.lastPathComponent, in: fixture.destination))
    }

    func testRetainedPackageRejectsFIFOsWithoutWaitingForAWritingProcess() throws {
      for name in ["manifest.json", "omarchy.img.zst"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        let importer = EngineHandoffPackageImporter()
        let imported = try importer.prepare(from: source, in: fixture.destination)
        let file = imported.packageURL.appendingPathComponent(name)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(
          try importer.reopenRetained(
            named: imported.packageURL.lastPathComponent, in: fixture.destination)
        ) {
          XCTAssertEqual($0 as? EngineHandoffImportError, .unsafeFile(name))
        }
      }
    }

    func testRecoveryContainerIsImportedWithItsDigestAndRejectsUnsafeSource() throws {
      for mode in ["valid", "changed", "symlink", "fifo", "renamed", "oversize"] {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = Data("bounded recovery container".utf8)
        let archive = fixture.source.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
        try writePrivate(bytes, to: archive)
        let manifestURL = fixture.source.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["recovery_template"] = [
          "file_name": mode == "renamed" ? "foreign.json" : NativeRecoveryTemplate.archiveFileName,
          "digest": digest(bytes),
          "size_bytes": mode == "oversize"
            ? Int(NativeRecoveryTemplate.maximumArchiveBytes + 1) : bytes.count,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
          to: manifestURL, options: .atomic)
        switch mode {
        case "changed": try Data("changed container".utf8).write(to: archive, options: .atomic)
        case "symlink":
          try FileManager.default.removeItem(at: archive)
          try FileManager.default.createSymbolicLink(
            at: archive, withDestinationURL: fixture.metadataURL)
        case "fifo":
          try FileManager.default.removeItem(at: archive)
          XCTAssertEqual(mkfifo(archive.path, 0o600), 0)
        default: break
        }
        let source = try openDirectory(fixture.source)
        defer { try? source.close() }
        if mode == "valid" {
          let imported = try EngineHandoffPackageImporter().prepare(
            from: source, in: fixture.destination)
          XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.recoveryTemplateURL)), bytes)
          XCTAssertEqual(try modeOfRecovery(imported.recoveryTemplateURL!), 0o400)
          let reopened = try EngineHandoffPackageImporter().reopenRetained(
            named: imported.packageURL.lastPathComponent, in: fixture.destination)
          XCTAssertEqual(reopened.recoveryTemplateURL, imported.recoveryTemplateURL)
          XCTAssertEqual(chmod(imported.recoveryTemplateURL!.path, 0o600), 0)
          try Data("tampered".utf8).write(to: imported.recoveryTemplateURL!)
          XCTAssertThrowsError(
            try EngineHandoffPackageImporter().reopenRetained(
              named: imported.packageURL.lastPathComponent, in: fixture.destination))
        } else {
          XCTAssertThrowsError(
            try EngineHandoffPackageImporter().prepare(from: source, in: fixture.destination))
          XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
        }
      }
    }

    private func modeOfRecovery(_ url: URL) throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func testGrowingRecoveryInputIsRejectedBeforeWritingBeyondItsDeclaredSize() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let bytes = Data("bounded recovery container".utf8)
      let archive = fixture.source.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
      try writePrivate(bytes, to: archive)
      let manifestURL = fixture.source.appendingPathComponent("manifest.json")
      var manifest = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
      manifest["recovery_template"] = [
        "file_name": NativeRecoveryTemplate.archiveFileName,
        "digest": digest(bytes), "size_bytes": bytes.count,
      ]
      try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
      let destination = fixture.destination
      let observed = ImportedByteObservation()
      let importer = EngineHandoffPackageImporter(readArtifactChunk: { role, source, limit in
        if role == "recovery-template" {
          // Observe any bytes already written before this read. An oversized
          // first read models growth after fstat, without a scheduling race.
          for package in try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)
          {
            let target = package.appendingPathComponent(NativeRecoveryTemplate.archiveFileName)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attributes[.size] as? NSNumber
            {
              observed.record(size.intValue)
            }
          }
          if try source.offset() == 0 {
            return (try source.read(upToCount: limit) ?? Data()) + Data([1])
          }
        }
        return try source.read(upToCount: limit)
      })
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }
      XCTAssertThrowsError(try importer.prepare(from: source, in: destination)) {
        XCTAssertEqual($0 as? EngineHandoffImportError, .sizeMismatch("recovery-template"))
      }
      // A clone holds exactly the declared bytes; nothing grows past them.
      XCTAssertLessThanOrEqual(observed.maximum, bytes.count)
      XCTAssertTrue(try importedEntries(in: destination).isEmpty)
    }

    func testValidPackageIsRecopiedIntoPrivateHelperDirectory() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      let imported = try EngineHandoffPackageImporter().prepare(
        from: source,
        in: fixture.destination
      )
      defer { try? FileManager.default.removeItem(at: imported.packageURL) }

      XCTAssertEqual(try mode(imported.packageURL), 0o700)
      XCTAssertEqual(try mode(imported.metadataURL), 0o400)
      XCTAssertEqual(
        try Data(contentsOf: imported.metadataURL),
        fixture.metadata
      )
      XCTAssertEqual(
        try Data(contentsOf: imported.payloadURL),
        fixture.payload
      )

      try FileManager.default.removeItem(at: fixture.metadataURL)
      try writePrivate(Data("changed!".utf8), to: fixture.metadataURL)
      XCTAssertEqual(try Data(contentsOf: imported.metadataURL), fixture.metadata)
    }

    func testUnknownManifestFieldIsRejectedBeforeImport() throws {
      let fixture = try makeFixture(extraManifestField: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .invalidManifest
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testReplacePackageImportsUnderInstallOperation() throws {
      let fixture = try makeFixture(replace: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      let imported = try EngineHandoffPackageImporter().prepare(
        from: source,
        in: fixture.destination
      )
      defer { try? FileManager.default.removeItem(at: imported.packageURL) }

      XCTAssertEqual(imported.installationIntent, .replace)
      XCTAssertEqual(try Data(contentsOf: imported.payloadURL), fixture.payload)
    }

    func testReplacePackageWithRepairManifestIsRejected() throws {
      let fixture = try makeFixture(replace: true, strayRepairManifest: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .bindingMismatch
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testReplacePackageUnderRepairOperationIsRejected() throws {
      let fixture = try makeFixture(replace: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let original = try String(
        contentsOf: fixture.requestURL,
        encoding: .utf8
      )
      let changed = original.replacingOccurrences(
        of: #""operation":"install""#,
        with: #""operation":"repair-installed-system""#
      )
      try FileManager.default.removeItem(at: fixture.requestURL)
      try writePrivate(Data(changed.utf8), to: fixture.requestURL)
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .invalidRequest
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testNulArtifactFileNameIsRejectedBeforeImport() throws {
      let fixture = try makeFixture(nulMetadataFileName: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .invalidManifest
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testChangedPayloadIsRejectedAndPartialImportIsRemoved() throws {
      let fixture = try makeFixture(corruptPayload: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .digestMismatch("payload")
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testChangedRequestExtentIsRejectedBeforeImport() throws {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let original = try String(
        contentsOf: fixture.requestURL,
        encoding: .utf8
      )
      let changed = original.replacingOccurrences(
        of: #""offset_bytes":2000"#,
        with: #""offset_bytes":3000"#
      )
      try FileManager.default.removeItem(at: fixture.requestURL)
      try writePrivate(Data(changed.utf8), to: fixture.requestURL)
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .bindingMismatch
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    func testSymlinkedMetadataIsRejectedAndPartialImportIsRemoved() throws {
      let fixture = try makeFixture(symlinkMetadata: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let source = try openDirectory(fixture.source)
      defer { try? source.close() }

      XCTAssertThrowsError(
        try EngineHandoffPackageImporter().prepare(
          from: source,
          in: fixture.destination
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineHandoffImportError,
          .unsafeFile("metadata")
        )
      }
      XCTAssertTrue(try importedEntries(in: fixture.destination).isEmpty)
    }

    private func makeFixture(
      extraManifestField: Bool = false,
      corruptPayload: Bool = false,
      symlinkMetadata: Bool = false,
      nulMetadataFileName: Bool = false,
      legacyEngine: Bool = false,
      repair: Bool = false,
      replace: Bool = false,
      reinstall: Bool = false,
      strayRepairManifest: Bool = false
    ) throws -> ImportFixture {
      // New packages are format 2 and name the built-in native engine. A
      // `legacyEngine` package is the format-1 shape older helpers retained.
      let native = !legacyEngine
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-helper-import-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      let source = root.appendingPathComponent("source", isDirectory: true)
      let destination = root.appendingPathComponent(
        "destination",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )

      let engine = Data("engine-a".utf8)
      let metadata = Data("metadata".utf8)
      let payload = Data("payload-a".utf8)
      let repairManifest = Data("{\"operation\":\"repair-installed-system\"}".utf8)
      let engineURL = source.appendingPathComponent("engine.tar.gz")
      let metadataURL = source.appendingPathComponent("installer-data.json")
      let payloadURL = source.appendingPathComponent("omarchy.img.zst")
      let repairURL = source.appendingPathComponent("repair.json")
      if !native {
        try writePrivate(engine, to: engineURL)
      }
      if symlinkMetadata {
        let target = source.appendingPathComponent("metadata-target")
        try writePrivate(metadata, to: target)
        try FileManager.default.createSymbolicLink(
          at: metadataURL,
          withDestinationURL: target
        )
      } else {
        try writePrivate(metadata, to: metadataURL)
      }
      try writePrivate(
        corruptPayload ? Data("payload-b".utf8) : payload,
        to: payloadURL
      )
      let includeRepairManifest = repair || strayRepairManifest
      if includeRepairManifest {
        try writePrivate(repairManifest, to: repairURL)
      }

      let bindingDigest = digest(Data("binding".utf8))
      let engineDigest = native ? NativeExecutionIdentity.digest : digest(engine)
      let metadataDigest = digest(metadata)
      let payloadDigest = digest(payload)
      let repairDigest = digest(repairManifest)
      let layoutDigest = digest(Data("layout".utf8))
      let engineVersion = native ? NativeExecutionIdentity.version : "v0.9.0-omarchy.2"
      let candidateKind = repair ? "repair" : reinstall ? "reinstall" : replace ? "replace" : "free"
      var planFields = [
        "apple,j314s", "disk0", layoutDigest, "free", "disk0s3",
        "2000", "1000", engineVersion, engineDigest, metadataDigest,
        payloadDigest,
      ]
      planFields[3] = candidateKind
      if includeRepairManifest {
        planFields.append(repairDigest)
      }
      let humanSteps =
        reinstall ? "authenticateMachineOwner" : "enterOneTrueRecovery,authenticateMachineOwner"
      planFields.append(humanSteps)
      let planDigest = lengthPrefixedDigest(planFields)
      let extraField = extraManifestField ? #","unexpected":true"# : ""
      let metadataFileName =
        nulMetadataFileName
        ? #"installer-data\u0000ignored.json"#
        : "installer-data.json"
      let engineField =
        native
        ? ""
        : ",\"engine\":{\"file_name\":\"engine.tar.gz\",\"digest\":\"\(engineDigest)\",\"size_bytes\":\(engine.count)}"
      let repairManifestField =
        includeRepairManifest
        ? ",\"repair_manifest\":{\"file_name\":\"repair.json\",\"digest\":\"\(repairDigest)\",\"size_bytes\":\(repairManifest.count)}"
        : ""
      let decoder = Data("decoder".utf8)
      try writePrivate(decoder, to: source.appendingPathComponent(RestoreImageHelper.fileName))
      let manifest = Data(
        """
        {"format":\(native ? 2 : 1),"binding_digest":"\(bindingDigest)","request_file":"request.json","identity_file":"identity.json"\(engineField),"metadata":{"file_name":"\(metadataFileName)","digest":"\(metadataDigest)","size_bytes":\(metadata.count)},"payload":{"file_name":"omarchy.img.zst","digest":"\(payloadDigest)","size_bytes":\(payload.count)},"restore_image":{"file_name":"\(RestoreImageHelper.fileName)","digest":"\(digest(decoder))","size_bytes":\(decoder.count)}\(repairManifestField)\(extraField)}
        """.utf8
      )
      let operation: String
      if repair {
        operation = "repair-installed-system"
      } else if reinstall {
        operation = ImportedInstallationIntent.reinstallOperation
      } else {
        operation = "install"
      }
      let humanStepsJSON =
        reinstall
        ? "[\"authenticateMachineOwner\"]"
        : "[\"enterOneTrueRecovery\",\"authenticateMachineOwner\"]"
      let request = Data(
        """
        {"format":1,"operation":"\(operation)","plan_digest":"\(planDigest)","device_identifier":"apple,j314s","store_identifier":"disk0","layout_digest":"\(layoutDigest)","candidate_kind":"\(candidateKind)","source_identifier":"disk0s3","offset_bytes":2000,"length_bytes":1000,"engine_version":"\(engineVersion)","required_human_steps":\(humanStepsJSON)}
        """.utf8
      )
      let identity = Data(
        """
        {"format":1,"binding_digest":"\(bindingDigest)","trust_root_fingerprint":"\(digest(Data("root".utf8)))","catalog_sequence":40,"catalog_payload_digest":"\(digest(Data("catalog".utf8)))","plan_digest":"\(planDigest)","engine_digest":"\(engineDigest)","metadata_digest":"\(metadataDigest)","payload_digest":"\(payloadDigest)"\(includeRepairManifest ? ",\"repair_manifest_digest\":\"\(repairDigest)\"" : "")}
        """.utf8
      )
      try writePrivate(
        manifest,
        to: source.appendingPathComponent("manifest.json")
      )
      try writePrivate(
        request,
        to: source.appendingPathComponent("request.json")
      )
      try writePrivate(
        identity,
        to: source.appendingPathComponent("identity.json")
      )

      return ImportFixture(
        root: root,
        source: source,
        destination: destination,
        metadataURL: metadataURL,
        requestURL: source.appendingPathComponent("request.json"),
        metadata: metadata,
        payload: payload
      )
    }

    /// Places the fixture's source files where an older helper kept a
    /// retained package: a private directory of owner-only copies.
    private func retainAsOlderHelperWould(_ fixture: ImportFixture) throws -> String {
      let name = "imported-handoff-" + UUID().uuidString.lowercased()
      let package = fixture.destination.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(
        at: package, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      for file in try FileManager.default.contentsOfDirectory(atPath: fixture.source.path) {
        let target = package.appendingPathComponent(file)
        try FileManager.default.copyItem(
          at: fixture.source.appendingPathComponent(file), to: target)
        try FileManager.default.setAttributes(
          [.posixPermissions: file == RestoreImageHelper.fileName ? 0o500 : 0o400],
          ofItemAtPath: target.path)
      }
      return name
    }

    private func openDirectory(_ url: URL) throws -> FileHandle {
      let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw CocoaError(.fileReadUnknown)
      }
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
      try data.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: url.path
      )
    }

    private func importedEntries(in directory: URL) throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    }

    private func mode(_ url: URL) throws -> mode_t {
      var status = stat()
      guard lstat(url.path, &status) == 0 else {
        throw CocoaError(.fileReadUnknown)
      }
      return status.st_mode & 0o777
    }

    private func digest(_ data: Data) -> String {
      "sha256:"
        + SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private func lengthPrefixedDigest(_ fields: [String]) -> String {
      let canonical =
        fields
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
      return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    }
  }

  private struct ImportFixture {
    let root: URL
    let source: URL
    let destination: URL
    let metadataURL: URL
    let requestURL: URL
    let metadata: Data
    let payload: Data
  }
#endif
