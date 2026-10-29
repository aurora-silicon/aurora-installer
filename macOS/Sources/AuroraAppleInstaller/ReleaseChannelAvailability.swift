#if os(macOS)
  import Foundation

  /// What one release channel offers this Mac, as the channel menu shows it.
  ///
  /// Only a verified catalog can say "no release" or "not for this Mac": a
  /// channel whose catalog cannot be fetched or verified is `checkFailed`,
  /// never mistaken for an empty one.
  public enum ReleaseChannelAvailability: Equatable, Sendable {
    /// The verified catalog admits this Mac.
    case available
    /// The verified catalog admits no Mac at all.
    case noRelease
    /// The verified catalog admits other Macs but not this one.
    case modelUnavailable(supportedDeviceIdentifiers: [String])
    case checkFailed(ReleaseChannelCheckFailure)

    public init(admittedDeviceIdentifiers: [String], deviceIdentifier: String) {
      if admittedDeviceIdentifiers.isEmpty {
        self = .noRelease
      } else if admittedDeviceIdentifiers.contains(deviceIdentifier) {
        self = .available
      } else {
        self = .modelUnavailable(supportedDeviceIdentifiers: admittedDeviceIdentifiers)
      }
    }

    public init(checkError error: any Error) {
      self = .checkFailed(ReleaseChannelCheckFailure(error))
    }

    /// Whether choosing this channel can lead anywhere. A channel that could
    /// not be checked stays selectable, so choosing it retries.
    public var isSelectable: Bool {
      switch self {
      case .available, .checkFailed: true
      case .noRelease, .modelUnavailable: false
      }
    }
  }

  public enum ReleaseChannelCheckFailure: Equatable, Sendable {
    /// The catalog could not be downloaded.
    case network
    /// A catalog arrived but failed its signature, format, or rollback check,
    /// or this app's own release configuration could not be read.
    case verification

    public init(_ error: any Error) {
      if error is URLError {
        self = .network
        return
      }
      switch error as? InstallerReleaseConfigurationError {
      case .unexpectedHTTPStatus:
        self = .network
      default:
        self = .verification
      }
    }
  }

  extension InstallerReleaseAssetCoordinator {
    /// Reads one channel's signed catalog and says what it offers this Mac.
    /// Read-only: it checks the rollback floor but records nothing.
    public func availability(
      configuration: InstallerReleaseConfiguration,
      channel: ReleaseChannel,
      deviceIdentifier: String,
      validationTime: Date,
      previouslyAcceptedCatalog: AcceptedCatalogIdentity?
    ) async -> ReleaseChannelAvailability {
      do {
        let admitted = try await supportedDeviceIdentifiers(
          configuration: configuration,
          channel: channel,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog
        )
        return ReleaseChannelAvailability(
          admittedDeviceIdentifiers: admitted,
          deviceIdentifier: deviceIdentifier
        )
      } catch {
        return ReleaseChannelAvailability(checkError: error)
      }
    }
  }
#endif
