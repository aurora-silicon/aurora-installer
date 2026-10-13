#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class AuthenticatedEngineXPCSubmitterTests: XCTestCase {
    /// A service nobody registered must fail the ping within the timeout,
    /// never hang: that is the whole point of pinging before submitting.
    func testPingFailsFastForAMissingService() async throws {
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: "com.omarchy.apple-installer.test.absent",
        helperCodeSigningRequirement:
          #"identifier "com.omarchy.apple-installer.helper""#
      )
      let started = Date()
      do {
        try await submitter.ping(timeout: .seconds(3))
        XCTFail("ping to an absent service must throw")
      } catch let error as EngineXPCSubmissionError {
        XCTAssertTrue(
          [.connectionFailed, .helperUnresponsive].contains(error),
          "unexpected \(error)"
        )
      }
      XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    /// A helper that is absent, or too old to know the call, reports no
    /// version instead of hanging or throwing.
    func testHelperVersionIsNilForAMissingService() async throws {
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: "com.omarchy.apple-installer.test.absent",
        helperCodeSigningRequirement:
          #"identifier "com.omarchy.apple-installer.helper""#
      )
      let started = Date()
      let version = await submitter.helperVersion(timeout: .seconds(2))
      XCTAssertNil(version)
      XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Third review: a removal that never reached the helper must not look
    /// like a reply lost after sending, which would hold the person in review.
    func testARemovalThatCannotBeSentIsNotSubmitted() async throws {
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: "com.omarchy.apple-installer.test.absent",
        helperCodeSigningRequirement:
          #"identifier "com.omarchy.apple-installer.helper""#
      )
      do {
        _ = try await submitter.removal()
        XCTFail("a removal to an absent helper must throw")
      } catch let error as EngineXPCSubmissionError {
        XCTAssertEqual(error, .notSubmitted)
      }
    }

    func testValidServiceAndRequirementAreAcceptedWithoutRegistration() throws {
      XCTAssertNoThrow(
        try AuthenticatedEngineXPCSubmitter(
          machServiceName: "com.omarchy.apple-installer.helper",
          helperCodeSigningRequirement:
            #"identifier "com.omarchy.apple-installer.helper""#
        )
      )
    }

    func testMalformedServiceNameIsRejected() {
      XCTAssertThrowsError(
        try AuthenticatedEngineXPCSubmitter(
          machServiceName: "../helper",
          helperCodeSigningRequirement:
            #"identifier "com.omarchy.apple-installer.helper""#
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineXPCSubmissionError,
          .invalidMachServiceName
        )
      }
    }

    func testMalformedRequirementIsRejectedBeforeXPCUse() {
      XCTAssertThrowsError(
        try AuthenticatedEngineXPCSubmitter(
          machServiceName: "com.omarchy.apple-installer.helper",
          helperCodeSigningRequirement: "("
        )
      ) {
        XCTAssertEqual(
          $0 as? EngineXPCSubmissionError,
          .invalidCodeSigningRequirement
        )
      }
    }

    func testRecoveryAuthorizationFailureCrossesXPCAsTypedSafeError() {
      let serviceError = EngineXPCErrorBridge.serviceError(
        for: PinnedAsahiEngineExecutionError.recoveryAuthorizationFailed
      )

      XCTAssertEqual(
        EngineXPCErrorBridge.submissionError(serviceError),
        .recoveryAuthorizationFailed
      )
      XCTAssertTrue(serviceError.userInfo.isEmpty)
      XCTAssertTrue(
        RecoveryAuthorizationRetryPolicy.isEligible(
          after: EngineXPCSubmissionError.recoveryAuthorizationFailed
        )
      )
      XCTAssertFalse(
        RecoveryAuthorizationRetryPolicy.isEligible(
          after: EngineXPCSubmissionError.helperRejected(
            domain: "example",
            code: 1
          )
        )
      )
    }
  }
#endif
