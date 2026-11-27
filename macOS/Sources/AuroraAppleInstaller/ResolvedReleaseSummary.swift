#if os(macOS)
  import CryptoKit
  import Foundation

  /// What one preparation resolved a channel to: the signed catalog it read and
  /// this Mac's build in it. Nightly and Edge are read from their feeds at
  /// install time, so the install log names the exact build instead of the
  /// channel alone. Built only from a catalog that has already verified.
  struct ResolvedReleaseSummary: Equatable {
    let channel: ReleaseChannel
    /// `sealed` for a catalog carried in this app, else the feed it came from.
    let source: String
    let sequence: UInt64?
    let issuedAt: String?
    let catalogSHA256: String
    let minimumSequence: UInt64?
    let deviceIdentifier: String
    let payloadDigest: String?
    let payloadURL: String?
    let downstreamRevision: String?
    let evidenceRevision: String?
    /// Edge only: the signed Linux and Mesa sources its qualification names.
    let linux: String?
    let mesa: String?

    init(
      payload: Data, channel: ReleaseChannel, sealed: Bool, feed: URL,
      minimumSequence: UInt64?, deviceIdentifier: String
    ) {
      self.channel = channel
      source = sealed ? "sealed" : feed.absoluteString
      catalogSHA256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      self.minimumSequence = minimumSequence
      self.deviceIdentifier = deviceIdentifier
      let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
      sequence = (object["sequence"] as? NSNumber)?.uint64Value
      issuedAt = object["issuedAt"] as? String
      let model = (object["models"] as? [[String: Any]])?.first {
        $0["deviceIdentifier"] as? String == deviceIdentifier
      }
      payloadDigest = model?["payloadDigest"] as? String
      payloadURL = (model?["payloadArtifact"] as? [String: Any])?["sourceURL"] as? String
      downstreamRevision = model?["downstreamRevision"] as? String
      evidenceRevision = model?["evidenceRevision"] as? String
      let qualification = object["edgeQualification"] as? [String: Any]
      linux = Self.source(qualification?["linux"])
      mesa = Self.source(qualification?["mesa"])
    }

    private static func source(_ value: Any?) -> String? {
      guard let source = value as? [String: Any], let revision = source["revision"] as? String
      else { return nil }
      return "\(source["branch"] as? String ?? "?")@\(revision)"
    }

    /// One install log line; absent fields are left out.
    var logLine: String {
      var fields = [
        "channel=\(channel.rawValue)", "source=\(source)",
        "sequence=\(sequence.map(String.init) ?? "?")",
      ]
      if let issuedAt { fields.append("issued=\(issuedAt)") }
      fields.append("catalog=sha256:\(catalogSHA256)")
      if let minimumSequence { fields.append("floor=\(minimumSequence)") }
      fields.append("mac=\(deviceIdentifier)")
      if let payloadDigest { fields.append("payload=\(payloadDigest)") }
      if let payloadURL { fields.append("from=\(payloadURL)") }
      if let downstreamRevision { fields.append("downstream=\(downstreamRevision)") }
      if let evidenceRevision { fields.append("evidence=\(evidenceRevision)") }
      if let linux { fields.append("linux=\(linux)") }
      if let mesa { fields.append("mesa=\(mesa)") }
      return "Resolved release: " + fields.joined(separator: " ")
    }
  }
#endif
