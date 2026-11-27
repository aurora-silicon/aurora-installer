#if os(macOS)
  import Foundation

  /// Applied only after the catalog signature and rollback floor are verified.
  /// The signed `channel` is what binds a catalog to the channel it is served
  /// on: every channel's catalog, an empty one included, must declare that
  /// channel, or the same signed bytes could be served on any of them. The one
  /// exception is Testing, whose published development deliveries predate the
  /// field: an undeclared catalog is accepted there only when it lists a model
  /// that isn't disabled and each of them is of that delivery lineage (or
  /// disabled). Those catalogs belong to Testing; they can never become Stable,
  /// RC or Edge.
  enum ReleaseCatalogChannelPolicy {
    static func validate(payload: Data, channel: ReleaseChannel) throws {
      guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
        let models = object["models"] as? [[String: Any]]
      else { throw InstallerReleaseConfigurationError.invalidCatalogChannel }
      let declared = object["channel"] as? String
      if object["channel"] != nil && declared == nil {
        throw InstallerReleaseConfigurationError.invalidCatalogChannel
      }
      guard channel == .edge else {
        if declared == channel.rawValue { return }
        guard channel == .testing, declared == nil,
          models.contains(where: { $0["status"] as? String != "disabled" }),
          models.allSatisfy(isLegacyDevelopment)
        else { throw InstallerReleaseConfigurationError.invalidCatalogChannel }
        return
      }
      // A catalog signed for another channel and served on Edge was mis-served
      // or replayed: that is a verification failure, as on every other
      // channel. Only an undeclared catalog means Edge has no Alpha yet.
      guard let declared else { throw InstallerReleaseConfigurationError.edgeAlphaUnavailable }
      guard declared == channel.rawValue else {
        throw InstallerReleaseConfigurationError.invalidCatalogChannel
      }
      if models.isEmpty { return }
      guard let envelope = try? JSONDecoder().decode(Envelope.self, from: payload) else {
        throw InstallerReleaseConfigurationError.invalidEdgeQualification
      }
      let qualification = envelope.edgeQualification
      guard qualification.schemaVersion == 1,
        qualification.releaseKind == "alpha",
        qualification.status == "passed",
        qualification.imageRunID > 0,
        SHA256Digest(rawValue: qualification.payloadDigest) != nil,
        SHA256Digest(rawValue: qualification.evidenceDigest) != nil,
        qualification.hasKnownSourceBranches,
        qualification.linux.isValid(repository: "aurora-silicon/linux"),
        qualification.mesa.isValid(repository: "aurora-silicon/mesa"),
        models.allSatisfy({ $0["payloadDigest"] as? String == qualification.payloadDigest })
      else { throw InstallerReleaseConfigurationError.invalidEdgeQualification }
    }

    /// The Macs a verified, qualified Edge catalog lists as family-qualified,
    /// by device identifier: each Mac's chip family passed the Edge rows on a
    /// named machine. Apply only to a payload `validate` accepted for Edge.
    /// `edgeQualification.devices` maps each such Mac to the digest of a
    /// detached evidence record that names it and its family's machine row; a
    /// `devices` value that isn't well formed qualifies no Mac. The app checks
    /// only that the map is well formed: what qualifies a family is the signed
    /// publisher's policy. The `apple,j700` `neoEvidence` fallback exists only
    /// for alpha.1 and alpha.2 Edge catalogs that predate the `devices` map
    /// and will be removed in a follow-up PR once the `fedora-kde` Edge
    /// catalog is re-published with `devices: {"apple,j700": ...}`. An
    /// explicit Edge pick doesn't need this.
    static func qualifiedDeviceIdentifiers(edgePayload payload: Data) -> Set<String> {
      guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
        object["channel"] as? String == "edge",
        let qualification = object["edgeQualification"] as? [String: Any]
      else { return [] }
      guard let devices = qualification["devices"] else {
        guard let neo = qualification["neoEvidence"] as? [String: Any], !neo.isEmpty
        else { return [] }
        return ["apple,j700"]
      }
      guard let entries = devices as? [String: Any] else { return [] }
      var proven = Set<String>()
      for (identifier, entry) in entries {
        guard isDeviceIdentifier(identifier),
          let evidence = entry as? [String: Any],
          let digest = evidence["evidenceDigest"] as? String,
          SHA256Digest(rawValue: digest) != nil
        else { return [] }
        proven.insert(identifier)
      }
      return proven
    }

    private static func isDeviceIdentifier(_ value: String) -> Bool {
      let prefix = "apple,"
      guard value.hasPrefix(prefix) else { return false }
      let board = value.utf8.dropFirst(prefix.utf8.count)
      return !board.isEmpty
        && board.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    /// The published development delivery lineage. scripts/
    /// prepare-distribution-release.py ports this exactly, and
    /// Fixtures/legacy-testing-catalog-vectors.json pins both to the same
    /// cases. The source must be the canonical release URL byte for byte.
    private static func isLegacyDevelopment(_ model: [String: Any]) -> Bool {
      if model["status"] as? String == "disabled" { return true }
      guard let profile = model["installationProfile"] as? String,
        let evidence = model["evidenceRevision"] as? String,
        evidence.hasPrefix("image-build-"),
        let artifact = model["payloadArtifact"] as? [String: Any],
        let fileName = artifact["fileName"] as? String,
        let source = artifact["sourceURL"] as? String,
        isFileName(fileName)
      else { return false }
      let run = String(evidence.dropFirst("image-build-".count))
      guard !run.isEmpty, run.first != "0", run.utf8.allSatisfy({ (48...57).contains($0) })
      else { return false }
      // Debian has no catalogs from before the channel field; its Testing
      // catalogs must declare it.
      let repositories = [
        "fedora": "fedora-aurora", "arch": "alarm-aurora",
        "nixos": "nixos-aurora", "omarchy": "omarchy-aurora",
      ]
      guard
        AuroraInstallationSelection.allProfileIDs.contains(where: {
          $0.utf8.elementsEqual(profile.utf8)
        }),
        let distribution = profile.split(separator: "-").first,
        let repository = repositories[String(distribution)]
      else { return false }
      let tag = "payload-\(profile)-\(run)"
      return [tag, tag + "-models58", tag + "-models65"].contains { release in
        source.utf8.elementsEqual(
          "https://github.com/aurora-silicon/\(repository)/releases/download/\(release)/\(fileName)"
            .utf8)
      }
    }

    /// ASCII letters and digits, then also `.`, `_`, `+` and `-`.
    private static func isFileName(_ value: String) -> Bool {
      let isAlphanumeric = { (byte: UInt8) in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      }
      guard let first = value.utf8.first, isAlphanumeric(first) else { return false }
      return value.utf8.allSatisfy { isAlphanumeric($0) || [46, 95, 43, 45].contains($0) }
    }

    private struct Envelope: Decodable {
      let edgeQualification: Qualification
    }

    private struct Qualification: Decodable {
      let schemaVersion: Int
      let releaseKind: String
      let status: String
      let imageRunID: UInt64
      let payloadDigest: String
      let evidenceDigest: String
      let linux: Source
      let mesa: Source

      var hasKnownSourceBranches: Bool {
        (linux.branch == "main" && mesa.branch == "aurora-wip")
          || (linux.branch == "aurora-edge" && mesa.branch == "aurora-edge")
      }
    }

    private struct Source: Decodable {
      let repository: String
      let branch: String
      let revision: String
      let tree: String

      func isValid(repository expected: String) -> Bool {
        repository == expected && isRevision(revision) && isRevision(tree)
      }

      private func isRevision(_ value: String) -> Bool {
        value.count == 40
          && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
          }
      }
    }
  }
#endif
