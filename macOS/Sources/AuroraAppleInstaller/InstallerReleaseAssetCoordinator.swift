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
    /// The owner's experimental hardware choice for a Mac the catalog does
    /// not list; nil on every supported Mac.
    public var experimental: ExperimentalAdmissionRecord? = nil

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
      let documents = try await catalogFetcher.fetch(
        configuration: configuration,
        channel: channel
      )
      return try AppleInstallerTrustCore().validateSupportCatalog(
        payload: documents.payload,
        signature: documents.signature,
        trustRoot: configuration.trustRoot,
        now: validationTime,
        previouslyAccepted: previouslyAcceptedCatalog
      ).deviceIdentifiers
    }

    public func prepareRelease(
      _ request: InstallerReleasePreparationRequest,
      progress: ArtifactStagingProgressHandler? = nil,
      previouslyPrepared: PreparedInstallerAssets? = nil,
      includePayload: Bool = true
    ) async throws -> PreparedInstallerRelease {
      _ = try assetPreparer.validateHost(request.host, experimental: request.experimental)
      let catalog = try await catalogFetcher.fetch(
        configuration: request.configuration,
        channel: request.channel
      )
      var assetRequest = InstallerAssetPreparationRequest(
        host: request.host,
        catalogPayload: catalog.payload,
        catalogSignature: catalog.signature,
        trustRoot: request.configuration.trustRoot,
        validationTime: request.validationTime,
        previouslyAcceptedCatalog: request.previouslyAcceptedCatalog,
        // A sealed catalog is distributed inside this signed app, so its
        // remote-update minimum cannot make the app outdated against itself.
        // Remote channel catalogs still enforce their minimum version.
        installerVersion: request.configuration.sealedCatalogDocuments == nil
          ? request.installerVersion : nil,
        stagingDirectory: request.stagingDirectory
      )
      assetRequest.experimental = request.experimental
      let assets = try await assetPreparer.prepare(
        assetRequest,
        progress: progress,
        previouslyPrepared: previouslyPrepared,
        includePayload: includePayload
      )
      return PreparedInstallerRelease(
        assets: assets,
        catalogDocuments: catalog
      )
    }
  }
#endif
