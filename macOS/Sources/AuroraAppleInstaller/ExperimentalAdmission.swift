import Foundation

/// The owner's experimental hardware choice, as the plan binds it.
///
/// A supported Mac's plan never carries one, so its plan digest is the same
/// bytes as before. An experimental plan appends this record's canonical text
/// as the last plan-digest field, so the helper's package import, the
/// transcript contract and the planner all bind it. The helper never trusts
/// it: it re-runs the decision on the live Mac and refuses unless the answer
/// is the same (`NativeExperimentalAdmission.verify`).
public struct ExperimentalAdmissionRecord: Codable, Equatable, Sendable {
  /// Bumped whenever the decision rules change, so a plan made by one version
  /// of the rules is never executed by another.
  public static let decisionVersion = "experimental-v1"
  /// SHA-256 of the typed phrase, normalised as the consent check does.
  public static let consentDigest = SHA256Digest(
    hashing: Data("install on untested hardware".utf8)
  ).rawValue

  public let schema: Int
  public let decision: String
  public let deviceIdentifier: String
  /// Lowercase hexadecimal, no prefix.
  public let chipID: String
  /// The level the owner chose. Which Stage 2 file it gets, and whether Full
  /// send falls back to Bootloader only, follow from the bound payload and
  /// this Mac's chip; the helper decides that itself and records it on the ESP.
  public let level: String
  public let stubFirmware: String
  public let consent: String

  enum CodingKeys: String, CodingKey {
    case schema
    case decision
    case deviceIdentifier = "device_identifier"
    case chipID = "chip_id"
    case level
    case stubFirmware = "stub_firmware"
    case consent
  }

  public init(deviceIdentifier: String, chipID: UInt64, level: String, stubFirmware: String) {
    schema = 1
    decision = Self.decisionVersion
    self.deviceIdentifier = deviceIdentifier
    self.chipID = String(chipID, radix: 16)
    self.level = level
    self.stubFirmware = stubFirmware
    consent = Self.consentDigest
  }

  /// Sorted keys, no whitespace: the exact text the plan digest binds.
  public var canonical: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding these plain fields cannot fail.
    return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
  }

  /// Accepts only the canonical text of a well-formed record of this
  /// decision version.
  public static func decode(_ text: String) throws -> Self {
    guard text.utf8.count <= 4096,
      let record = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
      record.canonical == text, record.schema == 1, record.decision == decisionVersion,
      record.consent == consentDigest,
      record.deviceIdentifier.range(
        of: #"\Aapple,j[0-9]+[a-z]*\z"#, options: .regularExpression) != nil,
      record.chipID.range(of: #"\A[0-9a-f]{1,8}\z"#, options: .regularExpression) != nil,
      ["bootloader-only", "full-send"].contains(record.level),
      !record.stubFirmware.isEmpty, record.stubFirmware.utf8.count <= 32
    else { throw ExperimentalAdmissionError.invalidRecord }
    return record
  }
}

public enum ExperimentalAdmissionError: Error, Equatable, Sendable {
  case invalidRecord
  /// The plan names a different Mac, chip or stub than the decision gives on
  /// this Mac now.
  case decisionChanged
  /// The Mac is supported or known broken: no experimental plan runs here.
  case notOffered
}
