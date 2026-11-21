#if os(macOS)
  import Foundation

  /// The release channel an installation came from, by the space it was
  /// installed into. A default for later plans only: it never authorizes a
  /// disk change, and a missing record means the channel is unknown.
  public struct InstallationChannelRecord: Codable, Equatable, Sendable {
    public let storeIdentifier: String
    public let offsetBytes: UInt64
    public let lengthBytes: UInt64
    public let channel: ReleaseChannel
  }

  /// What this app recorded when it installed each installation, so a Reset or
  /// boot loader update can read the channel the installation came from.
  /// Private to this user, like the pending installation hint.
  public struct InstallationChannelRecordStore: Sendable {
    public static let fileName = "installation-channels.json"
    static let maximumBytes = 65_536
    static let maximumRecords = 32
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The channel recorded for this installation, or `nil` when none was.
    public func channel(
      for installation: NativeKnownInstallation, storeIdentifier: String
    ) throws -> ReleaseChannel? {
      try load().last {
        $0.storeIdentifier == storeIdentifier
          && installation.overlaps(offsetBytes: $0.offsetBytes, lengthBytes: $0.lengthBytes)
      }?.channel
    }

    /// Records the channel an installation came from. Anything recorded for
    /// space it now occupies belonged to an installation that is gone.
    public func record(
      _ channel: ReleaseChannel, storeIdentifier: String, offsetBytes: UInt64,
      lengthBytes: UInt64
    ) throws {
      let space = NativeKnownInstallation(
        sourceIdentifier: storeIdentifier, offsetBytes: offsetBytes, lengthBytes: lengthBytes)
      // A file that doesn't decode, such as one cut short, would otherwise
      // block every later record. What it held is lost; this install's
      // record replaces it.
      let existing: [InstallationChannelRecord]
      do {
        existing = try load()
      } catch let error as DecodingError {
        InstallerLog.error(
          "\(Self.fileName) couldn't be decoded and is written again: \(error)")
        existing = []
      }
      var records = existing.filter {
        $0.storeIdentifier != storeIdentifier
          || !space.overlaps(offsetBytes: $0.offsetBytes, lengthBytes: $0.lengthBytes)
      }
      records.append(
        InstallationChannelRecord(
          storeIdentifier: storeIdentifier, offsetBytes: offsetBytes, lengthBytes: lengthBytes,
          channel: channel))
      let data = try JSONEncoder().encode(Array(records.suffix(Self.maximumRecords)))
      try PrivateInstallerJobFiles(directory: directory).write(
        data, name: Self.fileName, maximumBytes: Self.maximumBytes)
    }

    private func load() throws -> [InstallationChannelRecord] {
      guard
        let data = try PrivateInstallerJobFiles(directory: directory).read(
          Self.fileName, maximumBytes: Self.maximumBytes)
      else { return [] }
      return try JSONDecoder().decode([InstallationChannelRecord].self, from: data)
    }
  }
#endif
