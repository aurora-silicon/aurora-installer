import CryptoKit
import Foundation

public struct AppOwnedTrustRoot: Sendable {
  public let format: Int
  public let algorithm: String
  public let fingerprint: String
  private let publicKey: Curve25519.Signing.PublicKey

  public init(
    rawRepresentation: Data,
    expectedFingerprint: String
  ) throws {
    guard SHA256Digest(rawValue: expectedFingerprint) != nil else {
      throw AppOwnedTrustRootError.invalidFingerprint
    }
    guard
      let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: rawRepresentation
      )
    else {
      throw AppOwnedTrustRootError.invalidPublicKey
    }
    let fingerprint = SHA256Digest(hashing: rawRepresentation).rawValue
    guard fingerprint == expectedFingerprint else {
      throw AppOwnedTrustRootError.identityMismatch
    }

    format = 1
    algorithm = "ed25519"
    self.fingerprint = fingerprint
    self.publicKey = publicKey
  }

  var rawRepresentation: Data {
    publicKey.rawRepresentation
  }

}

public enum AppOwnedTrustRootError: Error, Equatable, Sendable {
  case identityMismatch
  case invalidFingerprint
  case invalidPublicKey
}

public struct CandidateBoundPlanIdentity: Equatable, Sendable {
  public let format: Int
  public let bindingDigest: String
  public let trustRootFingerprint: String
  public let catalogIdentity: AcceptedCatalogIdentity
  public let planDigest: String
  public let deviceIdentifier: String
  public let storeIdentifier: String
  public let layoutDigest: String
  public let candidateKind: String
  public let sourceIdentifier: String
  public let offsetBytes: UInt64
  public let lengthBytes: UInt64

  init(
    plan: ValidatedEnginePlan,
    catalogIdentity: AcceptedCatalogIdentity,
    trustRootFingerprint: String
  ) {
    format = 1
    self.trustRootFingerprint = trustRootFingerprint
    self.catalogIdentity = catalogIdentity
    planDigest = plan.planDigest
    deviceIdentifier = plan.deviceIdentifier
    storeIdentifier = plan.storeIdentifier
    layoutDigest = plan.layoutDigest
    candidateKind = plan.candidateKind
    sourceIdentifier = plan.sourceIdentifier
    offsetBytes = plan.offsetBytes
    lengthBytes = plan.lengthBytes
    bindingDigest = Self.makeBindingDigest(
      trustRootFingerprint: trustRootFingerprint,
      catalogSequence: catalogIdentity.sequence,
      catalogPayloadDigest: catalogIdentity.payloadDigest,
      planDigest: plan.planDigest,
      deviceIdentifier: plan.deviceIdentifier,
      storeIdentifier: plan.storeIdentifier,
      layoutDigest: plan.layoutDigest,
      candidateKind: plan.candidateKind,
      sourceIdentifier: plan.sourceIdentifier,
      offsetBytes: plan.offsetBytes,
      lengthBytes: plan.lengthBytes,
      engineDigest: plan.engineDigest,
      metadataDigest: plan.metadataDigest,
      payloadDigest: plan.payloadDigest)
  }

  /// The only definition of the binding digest. The app computes it for the
  /// plan it approves; the helper recomputes it from the control files of a
  /// package, so a package is admitted only when its fields give the digest
  /// it carries.
  static func makeBindingDigest(
    trustRootFingerprint: String,
    catalogSequence: UInt64,
    catalogPayloadDigest: String,
    planDigest: String,
    deviceIdentifier: String,
    storeIdentifier: String,
    layoutDigest: String,
    candidateKind: String,
    sourceIdentifier: String,
    offsetBytes: UInt64,
    lengthBytes: UInt64,
    engineDigest: String,
    metadataDigest: String,
    payloadDigest: String
  ) -> String {
    InstallerDigest.lengthPrefixedSHA256([
      // A fixed domain separator: changing it changes every binding digest.
      "omarchy.apple.candidate-bound-plan",
      "1",
      trustRootFingerprint,
      String(catalogSequence),
      catalogPayloadDigest,
      planDigest,
      deviceIdentifier,
      storeIdentifier,
      layoutDigest,
      candidateKind,
      sourceIdentifier,
      String(offsetBytes),
      String(lengthBytes),
      engineDigest,
      metadataDigest,
      payloadDigest,
    ]).rawValue
  }
}

public struct CandidateBoundPlanApproval: Sendable {
  public let identity: CandidateBoundPlanIdentity
  public let approvedBindingDigest: String

  public init(
    identity: CandidateBoundPlanIdentity,
    approvedBindingDigest: String
  ) {
    self.identity = identity
    self.approvedBindingDigest = approvedBindingDigest
  }
}
