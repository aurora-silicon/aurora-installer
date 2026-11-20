#if os(macOS)
  import Foundation

  /// Applied only after the catalog signature and rollback floor are verified.
  /// Legacy development catalogs belong to Testing; they can never become Edge.
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
        if let declared, declared != channel.rawValue {
          throw InstallerReleaseConfigurationError.invalidCatalogChannel
        }
        if channel == .testing && declared == nil && !models.allSatisfy(isLegacyDevelopment) {
          throw InstallerReleaseConfigurationError.invalidCatalogChannel
        }
        return
      }
      if models.isEmpty && (declared == nil || declared == "edge") { return }
      guard declared == "edge" else {
        throw InstallerReleaseConfigurationError.edgeAlphaUnavailable
      }
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
        qualification.linux.isValid(repository: "aurora-silicon/linux"),
        qualification.mesa.isValid(repository: "aurora-silicon/mesa"),
        models.allSatisfy({ $0["payloadDigest"] as? String == qualification.payloadDigest })
      else { throw InstallerReleaseConfigurationError.invalidEdgeQualification }
    }

    /// The Macs a verified, qualified Edge catalog proves, by device
    /// identifier. Apply only to a payload `validate` accepted for Edge.
    /// `edgeQualification.devices` maps each proven Mac to the digest of its
    /// own detached evidence record; a `devices` value that isn't well formed
    /// proves no Mac. A catalog from before `devices` proves only the MacBook
    /// Neo, through its `neoEvidence`. An explicit Edge pick doesn't need this.
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

    private static func isLegacyDevelopment(_ model: [String: Any]) -> Bool {
      if model["status"] as? String == "disabled" { return true }
      guard let profile = model["installationProfile"] as? String,
        let evidence = model["evidenceRevision"] as? String,
        evidence.hasPrefix("image-build-"),
        let artifact = model["payloadArtifact"] as? [String: Any],
        let fileName = artifact["fileName"] as? String,
        let source = artifact["sourceURL"] as? String,
        let url = URL(string: source),
        url.scheme == "https", url.host == "github.com", url.user == nil,
        url.password == nil, url.query == nil, url.fragment == nil
      else { return false }
      let run = String(evidence.dropFirst("image-build-".count))
      guard !run.isEmpty, run.first != "0", run.utf8.allSatisfy({ (48...57).contains($0) })
      else { return false }
      let repositories = [
        "fedora": "fedora-aurora", "arch": "alarm-aurora",
        "nixos": "nixos-aurora", "omarchy": "omarchy-aurora",
      ]
      guard AuroraInstallationSelection.allProfileIDs.contains(profile),
        let distribution = profile.split(separator: "-").first,
        let repository = repositories[String(distribution)]
      else { return false }
      let parts = url.pathComponents
      let tag = "payload-\(profile)-\(run)"
      return parts.count == 7 && parts[1] == "aurora-silicon" && parts[2] == repository
        && parts[3] == "releases" && parts[4] == "download"
        && [tag, tag + "-models58", tag + "-models65"].contains(parts[5])
        && parts[6] == fileName
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
    }

    private struct Source: Decodable {
      let repository: String
      let branch: String
      let revision: String
      let tree: String

      func isValid(repository expected: String) -> Bool {
        repository == expected && branch == "aurora-edge"
          && isRevision(revision) && isRevision(tree)
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
