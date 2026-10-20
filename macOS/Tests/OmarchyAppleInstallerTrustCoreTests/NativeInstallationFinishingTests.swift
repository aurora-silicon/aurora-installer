#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class NativeInstallationFinishingTests: XCTestCase, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
      let esp: NativeESPFileTests.Fixture
      let inputs: NativeNeoPeripheralInputTests.InputFixture
      let peripherals: PreparedNativePeripheralInputs?
      let machine: String
      let plan: NativeStubFilePlan
      let template: PreparedNativeRecoveryTemplate
      var imageOpens = 0
      var rejectDetach = false
      var attachment: URL?
      var base: NativeStubFileTests.ExecutionFixture { esp.images.base }
      init(machine: String = "j700") async throws {
        self.machine = machine
        let esp = try await NativeESPFileTests.Fixture(deviceIdentifier: "apple," + machine)
        self.esp = esp
        try await esp.prepare()
        let inputs = try NativeNeoPeripheralInputTests.InputFixture()
        self.inputs = inputs
        let peripherals =
          machine == "j700"
          ? try await inputs.preparer().prepare(package: inputs.package, rawDirectory: inputs.raw)
          : nil
        self.peripherals = peripherals
        let url = try XCTUnwrap(
          Bundle.module.url(
            forResource: "native-finishing", withExtension: "json", subdirectory: "Fixtures"))
        let document = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
        let archive = try await IPSWArchive.open(
          NativeStubFileTests.Source(
            bytes: XCTUnwrap(document[machine == "j700" ? "archive" : "archive-" + machine])))
        let plan = try await NativeStubFilePlan(
          archive: archive,
          source: .init(
            version: "26.6.2", sourceURL: URL(string: "https://example.test/restore.ipsw")!,
            stubBytes: 8 << 20),
          deviceClass: machine + "ap", boardID: 1, chipID: 2)
        self.plan = plan
        let base = esp.images.base
        try await NativeStubFilesExecution(
          package: base.package, approved: base.approved, plan: plan,
          owner: geteuid(), platform: base.platform, cache: nil
        ).prepare(
          journal: base.journal, authorization: base.authorization, sourceBootstrap: base.bootstrap)
        let vectors =
          try JSONSerialization.jsonObject(
            with: Data(
              contentsOf: XCTUnwrap(
                Bundle.module.url(
                  forResource: "native-handoff-vectors", withExtension: "json",
                  subdirectory: "Fixtures")))) as! [String: Any]
        let metadata = ((vectors["vectors"] as! [[String: Any]])[0]["metadata"] as! String)
        try Data(metadata.utf8).write(to: base.package.metadataURL)
        if let peripherals {
          let manifestURL = peripherals.directory.appendingPathComponent("manifest.json")
          var manifest =
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
          manifest["binding_digest"] = base.package.bindingDigest
          manifest["plan_digest"] = base.approved.planDigest
          manifest["metadata_digest"] = base.approved.metadataDigest
          manifest["payload_digest"] = base.approved.payloadDigest
          try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
            to: manifestURL)
        }
        let app = base.directory.appendingPathComponent("Template.app")
        try FileManager.default.createDirectory(
          at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try PropertyListSerialization.data(
          fromPropertyList: [
            "CFBundleExecutable": "OmarchyRecovery",
            "CFBundleDisplayName": InstallerProductIdentity.appName,
            "OmarchyRecoveryBuildMode": "recovery",
            "OmarchyRecoveryDataLayout": "external-install-data-v1",
          ], format: .xml, options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/OmarchyRecovery")
        try Data("synthetic Recovery executable".utf8).write(to: executable)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        template = try NativeRecoveryTemplate.prepare(
          source: app, in: base.directory, owner: geteuid(), requirement: "fixture",
          verify: { _ in })
      }
      deinit {
        try? peripherals?.remove()
        inputs.remove()
        template.remove()
      }
      var environment: NativeHandoffEnvironment {
        let original = esp.environment
        return NativeHandoffEnvironment(
          snapshot: original.snapshot, device: original.device,
          command: { executable, args in
            let data = try original.command(executable, args)
            if args == ["info", "-plist", "disk8s1"] {
              var object =
                try PropertyListSerialization.propertyList(from: data, format: nil)
                as! [String: Any]
              object["VolumeName"] = "Fedora Aurora Remix"
              return try PropertyListSerialization.data(
                fromPropertyList: object, format: .xml, options: 0)
            }
            return data
          }, ownerUUID: original.ownerUUID, rawDigest: esp.images.platform.digest,
          verifyRecovery: { _, _ in }, owner: geteuid(), mountRoot: original.mountRoot,
          sourcePrebootMount: original.sourcePrebootMount, verifyMount: original.verifyMount)
      }
      var vendor: NativeVendorFirmware {
        NativeVendorFirmware(
          package: base.package, approved: base.approved, plan: plan, peripherals: peripherals,
          owner: geteuid(), environment: environment, disks: esp.images.platform.disks,
          ambientLight: { self.machine == "j314s" ? Data("synthetic generic ALS".utf8) : nil },
          openImage: { _, parent in
            self.imageOpens += 1
            let directory = parent.appendingPathComponent("firmware-image-" + UUID().uuidString)
            self.attachment = directory
            let root = directory.appendingPathComponent("recovery")
            for path in ["usr/share/firmware/wifi", "usr/share/firmware/bluetooth", "usr/sbin"] {
              try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            }
            let camera =
              self.machine == "j700"
              ? Data("raw camera fallback".utf8)
              : try XCTUnwrap(
                self.inputs.value.rawFiles.first { $0.key.hasPrefix("camera/") }?.value)
            try camera.write(to: root.appendingPathComponent("usr/sbin/appleh13camerad"))
            if self.machine != "j700" {
              let url = try XCTUnwrap(
                Bundle.module.url(
                  forResource: "native-finishing", withExtension: "json", subdirectory: "Fixtures"))
              let document = try JSONDecoder().decode(
                [String: Data].self, from: Data(contentsOf: url))
              for (name, data) in document where name.hasPrefix("radio/") {
                let path = root.appendingPathComponent("usr/share/firmware/" + name.dropFirst(6))
                try FileManager.default.createDirectory(
                  at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                  attributes: [.posixPermissions: 0o700])
                try data.write(to: path)
              }
            }
            return NativeFirmwareMountedImage(
              directory: directory, root: root, device: "disk99s1",
              command: { _, args in
                XCTAssertEqual(args, ["detach", "/dev/disk99s1"])
                if self.rejectDetach { throw NativeFirmwareInputFailure.detachFailed }
                return Data()
              })
          },
          factoryFiles: { _ in
            [
              "BWC2-synthetic": self.inputs.value.local["factory"]!,
              "HmCA-synthetic": Data("synthetic factory ALS".utf8),
            ]
          },
          admitESPFilesystem: { _ in })
      }
      var recovery: NativeRecoveryInstallation {
        NativeRecoveryInstallation(
          package: base.package, approved: base.approved, template: template,
          owner: geteuid(), environment: environment, disks: esp.images.platform.disks,
          verifyApp: { _, requirement in XCTAssertEqual(requirement, "fixture") },
          admitESPFilesystem: { _ in })
      }
      var completion: NativeInstallationCompletion {
        NativeInstallationCompletion(
          package: base.package, approved: base.approved, owner: geteuid(),
          environment: environment, disks: esp.images.platform.disks, admitESPFilesystem: { _ in })
      }
      func prepareVendor() async throws -> NativeVendorFirmware.Receipt {
        try await vendor.prepare(
          journal: base.journal, authorization: base.authorization, bootstrap: base.bootstrap)
      }
      func prepareRecovery() async throws {
        try await recovery.prepare(
          journal: base.journal, authorization: base.authorization, bootstrap: base.bootstrap)
      }
      var vendorEvidence: URL {
        URL(fileURLWithPath: base.journal.path + ".native-vendor-firmware.evidence")
      }
      var system: URL { base.mounts.appendingPathComponent("disk8s1") }
    }

    func testGenericLaptopAndSensorlessDesktopFinishWithoutNeoInputs() async throws {
      for machine in ["j314s", "j274"] {
        let fixture = try await Fixture(machine: machine)
        XCTAssertNil(fixture.peripherals)
        _ = try await fixture.prepareVendor()
        let manifest = try String(
          contentsOf: fixture.esp.esp.appendingPathComponent("vendorfw/manifest.txt"),
          encoding: .utf8)
        XCTAssertTrue(manifest.contains("apple/isp_1921_01XX.dat"))
        XCTAssertTrue(manifest.contains("asmedia/asm2214a-apple.bin"))
        XCTAssertTrue(manifest.contains("brcm/brcmfmac4355c1-pcie.apple,j314s.bin"))
        XCTAssertTrue(manifest.contains("brcm/brcmbt4388b0-apple,tokara-a.bin"))
        XCTAssertFalse(manifest.contains("mediatek/"))
        XCTAssertFalse(manifest.contains("j700"))
        XCTAssertEqual(manifest.contains("apple/tpmtfw-j314s.bin"), machine == "j314s")
        XCTAssertEqual(manifest.contains("apple/aop-als-cal.bin"), machine == "j314s")
        XCTAssertEqual(manifest.contains("apple/HmCA-synthetic"), machine == "j314s")
        XCTAssertFalse(manifest.contains("apple/tpmtfw-j274.bin"))
        try await fixture.prepareRecovery()
        try await fixture.completion.prepare(
          journal: fixture.base.journal, authorization: fixture.base.authorization,
          bootstrap: fixture.base.bootstrap)
        let file = try NativeInstallJournalFile(
          url: fixture.base.journal, package: fixture.base.package, owner: geteuid())
        let snapshot = try NativeRecoveryJournalSnapshot.decode(
          file.readJournal(), package: fixture.base.package, evidence: file.readEvidence)
        XCTAssertEqual(snapshot.state, .ready)
      }
    }

    func testAmbientLightAbsenceAndCalibrationPublicationHaveSeparateContracts() throws {
      let factory = ["HmCA-local": Data([1, 2, 3]), "BWC2-local": Data([4, 5, 6])]
      XCTAssertEqual(try NativeAmbientLightInputs.files(calibration: nil, factory: factory), [:])
      XCTAssertEqual(
        try NativeAmbientLightInputs.files(calibration: Data([7]), factory: factory),
        ["apple/aop-als-cal.bin": Data([7]), "apple/HmCA-local": Data([1, 2, 3])])
      XCTAssertThrowsError(
        try NativeAmbientLightInputs.files(calibration: Data(), factory: factory))
      XCTAssertThrowsError(
        try NativeAmbientLightInputs.files(
          calibration: Data([7]), factory: ["HmCA/../outside": Data([1])]))
    }

    func testNativeFirmwareRecoveryAndFinalCheckpointAreAcceptedTogether() async throws {
      let fixture = try await Fixture()
      let receipt = try await fixture.prepareVendor()
      XCTAssertTrue(receipt.installerData.keys.contains("asahi/SystemVersion.plist"))
      XCTAssertTrue(receipt.installerData.keys.contains("asahi/BuildManifest.plist"))
      let second = try await fixture.prepareVendor()
      XCTAssertEqual(receipt, second)
      XCTAssertEqual(fixture.imageOpens, 1)
      try await fixture.prepareRecovery()
      try await fixture.completion.prepare(
        journal: fixture.base.journal, authorization: fixture.base.authorization,
        bootstrap: fixture.base.bootstrap)
      let file = try NativeInstallJournalFile(
        url: fixture.base.journal, package: fixture.base.package, owner: geteuid())
      let snapshot = try NativeRecoveryJournalSnapshot.decode(
        file.readJournal(), package: fixture.base.package, evidence: file.readEvidence)
      XCTAssertEqual(snapshot.state, .ready)
      let evidence = try NativeHandoffEvidence(
        snapshot: snapshot, metadata: Data(contentsOf: fixture.base.package.metadataURL))
      XCTAssertEqual(
        evidence.installed.apfsVgid, fixture.base.snapshot.containers[1].volumes[0].group)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.system.appendingPathComponent("Aurora Installer.app").path))
    }

    func testInterruptedVendorPublicationRebuildsExactlyAndAdoptsExistingFiles() async throws {
      let fixture = try await Fixture()
      let expected = try await fixture.prepareVendor()
      try FileManager.default.removeItem(at: fixture.vendorEvidence)
      // Some files were committed before a crash; the rest were not.
      try FileManager.default.removeItem(
        at: fixture.esp.esp.appendingPathComponent("vendorfw/manifest.txt"))
      let restored = try await fixture.prepareVendor()
      XCTAssertEqual(restored, expected)
      XCTAssertEqual(fixture.imageOpens, 2)
      let fallback = fixture.esp.esp.appendingPathComponent("asahi/all_firmware.tar.gz")
      XCTAssertEqual(
        try NativeStubFileStore.hash(Data(contentsOf: fallback)),
        expected.installerData["asahi/all_firmware.tar.gz"]?.sha256)
    }

    func testRecoveryResumesPartialDataAndMissingAppWithoutReplacingSystem() async throws {
      let fixture = try await Fixture()
      _ = try await fixture.prepareVendor()
      try await fixture.prepareRecovery()
      let sentinel = fixture.system.appendingPathComponent("retain")
      try Data("preserve System".utf8).write(to: sentinel)
      let app = fixture.system.appendingPathComponent(
        InstallerProductIdentity.recoveryAppBundleName)
      try FileManager.default.removeItem(at: app)
      let data = fixture.system.appendingPathComponent("Aurora/Recovery/InstallData")
      let candidate = data.deletingLastPathComponent().appendingPathComponent(
        ".native-install-data-" + String(fixture.base.approved.planDigest.dropFirst(7)))
      try FileManager.default.moveItem(at: data, to: candidate)
      try FileManager.default.removeItem(
        at: candidate.appendingPathComponent("AuraPayloads/raw/boot.bin"))
      try await fixture.prepareRecovery()
      XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve System".utf8))
      XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
      try Data("changed".utf8).write(to: data.appendingPathComponent("AuraPayloads/raw/boot.bin"))
      do {
        try await fixture.prepareRecovery()
        XCTFail("Changed Recovery data was adopted")
      } catch {}
    }

    func testFailedImageDetachDoesNotLetOuterCleanupDeleteTheAttachment() async throws {
      let fixture = try await Fixture()
      fixture.rejectDetach = true
      do {
        _ = try await fixture.prepareVendor()
        XCTFail("Detach failure was ignored")
      } catch {}
      let attachment = try XCTUnwrap(fixture.attachment)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: attachment.appendingPathComponent("recovery/usr/sbin/appleh13camerad").path))
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: fixture.base.directory.path).contains {
          $0.hasPrefix("vendor-firmware-")
        })
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vendorEvidence.path))
    }
  }
#endif
