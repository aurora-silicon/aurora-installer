#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  final class ExperimentalAdmissionBindingTests: XCTestCase {
    private let mac27 = NativeInspectionHardware(
      chipID: 0x6040, bootVersion: "mBoot-20457.1.29", macOSVersion: "27.0",
      recoveryVersion: "26.1.0.0.0,0")

    private func message(_ experimental: String?) -> EnginePlanMessage {
      EnginePlanMessage(
        planDigest: "", deviceIdentifier: "apple,j614s", storeIdentifier: "disk0",
        layoutDigest: "sha256:" + String(repeating: "a", count: 64), candidateKind: "free",
        sourceIdentifier: "disk0s2", offsetBytes: 4096, lengthBytes: 1 << 34,
        engineVersion: "native-v1", engineDigest: "sha256:" + String(repeating: "b", count: 64),
        metadataDigest: "sha256:" + String(repeating: "c", count: 64),
        payloadDigest: "sha256:" + String(repeating: "d", count: 64), repairManifestDigest: nil,
        requiredHumanSteps: ["enterOneTrueRecovery", "authenticateMachineOwner"],
        experimentalAdmission: experimental)
    }

    private func record() throws -> ExperimentalAdmissionRecord {
      let assessment = try NativeExperimentalHardware.assess(
        "apple,j614s", hardware: mac27, policy: NativeInspectionPolicy.sealed(),
        metadata: ExperimentalHardwareInspection.anyPayload(), level: .fullSend)
      return NativeDeviceAdmission.record(assessment)
    }

    func testAPlanWithoutARecordKeepsItsDigest() {
      let plan = message(nil)
      let fields = [
        plan.deviceIdentifier, plan.storeIdentifier, plan.layoutDigest, plan.candidateKind,
        plan.sourceIdentifier, String(plan.offsetBytes), String(plan.lengthBytes),
        plan.engineVersion, plan.engineDigest, plan.metadataDigest, plan.payloadDigest,
        plan.requiredHumanSteps.joined(separator: ","),
      ]
      XCTAssertEqual(
        plan.computedPlanDigest, InstallerDigest.lengthPrefixedSHA256(fields).hexadecimal)
    }

    func testTheRecordIsTheLastDigestField() throws {
      let canonical = try record().canonical
      let bound = message(canonical)
      XCTAssertNotEqual(bound.computedPlanDigest, message(nil).computedPlanDigest)
      XCTAssertNotEqual(
        bound.computedPlanDigest,
        message(canonical.replacingOccurrences(of: "full-send", with: "bootloader-only"))
          .computedPlanDigest)
    }

    func testOnlyTheCanonicalRecordDecodes() throws {
      let canonical = try record().canonical
      XCTAssertEqual(try ExperimentalAdmissionRecord.decode(canonical).canonical, canonical)
      XCTAssertThrowsError(try ExperimentalAdmissionRecord.decode(canonical + " "))
      XCTAssertThrowsError(
        try ExperimentalAdmissionRecord.decode(
          canonical.replacingOccurrences(of: ExperimentalAdmissionRecord.consentDigest, with: "x")))
    }

    func testTheHelperRecheckAgreesOrRefuses() throws {
      let policy = try NativeInspectionPolicy.sealed()
      let any = try ExperimentalHardwareInspection.anyPayload()
      let record = try record()
      XCTAssertNoThrow(
        try NativeDeviceAdmission.verify(
          record, deviceIdentifier: "apple,j614s", hardware: mac27, policy: policy, metadata: any))
      let otherChip = NativeInspectionHardware(
        chipID: 0x6041, bootVersion: mac27.bootVersion, macOSVersion: mac27.macOSVersion,
        recoveryVersion: mac27.recoveryVersion)
      XCTAssertThrowsError(
        try NativeDeviceAdmission.verify(
          record, deviceIdentifier: "apple,j614s", hardware: otherChip, policy: policy,
          metadata: any))
      XCTAssertThrowsError(
        try NativeDeviceAdmission.verify(
          record, deviceIdentifier: "apple,j616s", hardware: mac27, policy: policy, metadata: any))
      // A supported Mac never takes the experimental path, even with a record.
      let supported = NativeDeviceAdmission.record(
        try NativeExperimentalHardware.assess(
          "apple,j614s", hardware: mac27, policy: policy, metadata: any, level: .bootloaderOnly))
      XCTAssertFalse(
        NativeDeviceAdmission.admits(
          deviceIdentifier: "apple,j616s", admission: supported, hardware: { self.mac27 }))
      XCTAssertTrue(
        NativeDeviceAdmission.admits(
          deviceIdentifier: "apple,j616s", admission: nil, hardware: { self.mac27 }))
      XCTAssertFalse(
        NativeDeviceAdmission.admits(
          deviceIdentifier: "apple,j614s", admission: nil, hardware: { self.mac27 }))
    }

    func testWithoutARecordThePolicyIsTheSealedOne() throws {
      let sealed = try NativeInspectionPolicy.sealed()
      let policy = try NativeDeviceAdmission.policy(
        deviceIdentifier: "apple,j616s", admission: nil, hardware: mac27,
        metadata: ExperimentalHardwareInspection.anyPayload())
      XCTAssertEqual(policy.devices.keys.sorted(), sealed.devices.keys.sorted())
      XCTAssertEqual(policy.chipMinimum, sealed.chipMinimum)
    }
  }
#endif
