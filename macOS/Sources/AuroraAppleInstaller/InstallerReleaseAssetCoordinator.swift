#if os(macOS)
  import Foundation

  public struct InstallerReleasePreparationRequest: Sendable {
    public let host: AppleSiliconHostInspection
    public let configuration: InstallerReleaseConfiguration
    public let channel: ReleaseChannel
    public let validationTime: Date
    public let previouslyAcceptedCatalog: AcceptedCatalogIdentity?
    public let installerVersion: InstallerVersion?
    public let stagingDirectory: URL

    public init(
      host: AppleSiliconHostInspection,
      configuration: InstallerReleaseConfiguration,
      channel: ReleaseChannel,
      validationTime: Date,
      previouslyAcceptedCatalog: AcceptedCatalogIdentity? = nil,
      installerVersion: InstallerVersion? = nil,
      stagingDirectory: URL
    ) {
      self.host = host
      self.configuration = configuration
      self.channel = channel
      self.validationTime = validationTime
      self.previouslyAcceptedCatalog = previouslyAcceptedCatalog
      self.installerVersion = installerVersion
      self.stagingDirectory = stagingDirectory
    }
  }

  public struct PreparedInstallerRelease: Sendable {
    public let assets: PreparedInstallerAssets
    public let catalogDocuments: InstallerReleaseCatalogDocuments
    /// The build's floor that `catalogDocuments` was checked against, carried
    /// so planning re-validates the same catalog against the same floor.
    public let minimumCatalogSequence: UInt64?

    init(
      assets: PreparedInstallerAssets,
      catalogDocuments: InstallerReleaseCatalogDocuments,
      minimumCatalogSequence: UInt64? = nil
    ) {
      self.assets = assets
      self.catalogDocuments = catalogDocuments
      self.minimumCatalogSequence = minimumCatalogSequence
    }
  }

  public struct InstallerReleaseAssetCoordinator: Sendable {
    private let catalogFetcher: InstallerReleaseCatalogFetcher
    private let assetPreparer: InstallerAssetPreparer

    public init() {
      catalogFetcher = InstallerReleaseCatalogFetcher()
      assetPreparer = InstallerAssetPreparer()
    }

    init(
      catalogFetcher: InstallerReleaseCatalogFetcher,
      assetPreparer: InstallerAssetPreparer
    ) {
      self.catalogFetcher = catalogFetcher
      self.assetPreparer = assetPreparer
    }

    public func prepare(
      _ request: InstallerReleasePreparationRequest,
      progress: ArtifactStagingProgressHandler? = nil
    ) async throws -> PreparedInstallerAssets {
      try await prepareRelease(request, progress: progress).assets
    }

    /// The device identifiers the channel's signed catalog admits, for
    /// telling an unsupported Mac which models this release covers. Read-only:
    /// it verifies the signature and rollback floor but records nothing.
    public func supportedDeviceIdentifiers(
      configuration: InstallerReleaseConfiguration,
      channel: ReleaseChannel,
      validationTime: Date,
      previouslyAcceptedCatalog: AcceptedCatalogIdentity?
    ) async throws -> [String] {
      try await verifiedCatalog(
        configuration: configuration,
        channel: channel,
        validationTime: validationTime,
        previouslyAcceptedCatalog: previouslyAcceptedCatalog
      ).deviceIdentifiers
    }

    /// One channel's catalog, after its signature, rollback floor (the stored
    /// one and the build's own) and channel policy are verified.
    func verifiedCatalog(
      configuration: InstallerReleaseConfiguration,
      channel: ReleaseChannel,
      validationTime: Date,
      previouslyAcceptedCatalog: AcceptedCatalogIdentity?
    ) async throws -> (payload: Data, deviceIdentifiers: [String]) {
      let documents = try await catalogFetcher.fetch(
        configuration: configuration,
        channel: channel
      )
      let support = try AppleInstallerTrustCore().validateSupportCatalog(
        payload: documents.payload,
        signature: documents.signature,
        trustRoot: configuration.trustRoot,
        now: validationTime,
        previouslyAccepted: previouslyAcceptedCatalog,
        minimumSequence: configuration.minimumCatalogSequence[channel]
      )
      try ReleaseCatalogChannelPolicy.validate(payload: documents.payload, channel: channel)
      return (documents.payload, support.deviceIdentifiers)
    }

    public func prepareRelease(
      _ request: InstallerReleasePreparationRequest,
      progress: ArtifactStagingProgressHandler? = nil,
      previouslyPrepared: PreparedInstallerAssets? = nil,
      includePayload: Bool = true
    ) async throws -> PreparedInstallerRelease {
      _ = try assetPreparer.validateHost(request.host)
      let catalog = try await catalogFetcher.fetch(
        configuration: request.configuration,
        channel: request.channel
      )
      let minimumSequence = request.configuration.minimumCatalogSequence[
        request.channel
      ]
      _ = try AppleInstallerTrustCore().validateSupportCatalog(
        payload: catalog.payload,
        signature: catalog.signature,
        trustRoot: request.configuration.trustRoot,
        now: request.validationTime,
        previouslyAccepted: request.previouslyAcceptedCatalog,
        minimumSequence: minimumSequence
      )
      try ReleaseCatalogChannelPolicy.validate(payload: catalog.payload, channel: request.channel)
      let configuration = request.configuration
      InstallerLog.progress(
        ResolvedReleaseSummary(
          payload: catalog.payload, channel: request.channel,
          sealed: configuration.sealedCatalogDocuments != nil
            && request.channel == configuration.defaultChannel,
          feed: configuration.catalogURL(for: request.channel), minimumSequence: minimumSequence,
          deviceIdentifier: request.host.identity.deviceIdentifier
        ).logLine)
      let assets = try await assetPreparer.prepare(
        InstallerAssetPreparationRequest(
          host: request.host,
          catalogPayload: catalog.payload,
          catalogSignature: catalog.signature,
          trustRoot: request.configuration.trustRoot,
          validationTime: request.validationTime,
          previouslyAcceptedCatalog: request.previouslyAcceptedCatalog,
          // A sealed catalog is distributed inside this signed app, so its
          // remote-update minimum cannot make the app outdated against itself.
          // Remote channel catalogs still enforce their minimum version.
          installerVersion: request.configuration.sealedCatalogDocuments != nil
            && request.channel == request.configuration.defaultChannel
            ? nil : request.installerVersion,
          stagingDirectory: request.stagingDirectory,
          minimumCatalogSequence: minimumSequence
        ),
        progress: progress,
        previouslyPrepared: previouslyPrepared,
        includePayload: includePayload
      )
      return PreparedInstallerRelease(
        assets: assets,
        catalogDocuments: catalog,
        minimumCatalogSequence: minimumSequence
      )
    }
  }
#endif
