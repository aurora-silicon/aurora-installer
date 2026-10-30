import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import Foundation

/// The real installer environment.
///
/// It owns the trust objects the screens must never see — the host inspection,
/// the engine transcripts, the prepared plan, the review, the approval, and the
/// release configuration — and hands the UI only render-only display models.
/// Approval is always rebuilt from the retained review, never from a display
/// model, and no credential is ever stored here.
final class LiveInstallerEnvironment: InstallerEnvironment, @unchecked Sendable {
  private let lock = NSLock()
  private let selection: AuroraInstallationSelection
  private let inspector: any NativeInstallerInspecting
  private let inspectHost: @Sendable () throws -> AppleSiliconHostInspection
  private let helperProbe: @Sendable () async -> HelperDisplay
  private let recoveryAccountInspector: (@Sendable () async throws -> RecoveryAccountReply)?

  init(
    selection: AuroraInstallationSelection = AuroraInstallationSelection(),
    inspector: any NativeInstallerInspecting = NativeInstallerInspector(),
    inspectHost: @escaping @Sendable () throws -> AppleSiliconHostInspection = {
      try AppleSiliconHostInspector().inspect()
    },
    prefetch: PayloadPrefetchOrchestrator = PayloadPrefetchOrchestrator(),
    helperProbe: @escaping @Sendable () async -> HelperDisplay = {
      await InstallerHelperSetup.probeDisplay()
    },
    recoveryAccountInspector: (@Sendable () async throws -> RecoveryAccountReply)? = nil
  ) {
    self.selection = selection
    self.inspector = inspector
    self.inspectHost = inspectHost
    self.prefetch = prefetch
    self.helperProbe = helperProbe
    self.recoveryAccountInspector = recoveryAccountInspector
  }

  private func loadConfiguration() throws -> InstallerReleaseConfiguration {
    guard let resources = Bundle.main.resourceURL else {
      throw AuroraProfileError.unavailable(selection.summary)
    }
    let directory = resources.appendingPathComponent("Release/Profiles")
      .appendingPathComponent(selection.profileID)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw AuroraProfileError.unavailable(selection.summary)
    }
    return try InstallerReleaseConfigurationLocator().load(from: directory)
  }
  private var hostInspection: AppleSiliconHostInspection?
  private var engineInspection: ValidatedEngineTranscript?
  private var engineInspectionTranscript: Data?
  private var engineInspectionFailure: String?
  private var planReview: InstallerPlanReview?
  private var preparedPlan: PreparedInstallerPlanExecution?
  private var planApproval: CandidateBoundPlanApproval?
  private var reusableAssets: PreparedInstallerAssets?
  private var releaseConfiguration: InstallerReleaseConfiguration?
  private let buildProfile = InstallerBuildProfile.current
  private var encryptLinuxDisk = true
  private var selectedLane = ReleaseChannel.stable.rawValue
  private let prefetch: PayloadPrefetchOrchestrator
  private var plannedPayload: StagedInstallerArtifact?
  private var preparationGeneration = UUID()

  private func inspectCurrentHost() async throws -> AppleSiliconHostInspection {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let host = try self.inspectHost()
      try Task.checkCancellation()
      return host
    }
    let host = try await withTaskCancellationHandler(
      operation: { try await worker.value }, onCancel: { worker.cancel() })
    try Task.checkCancellation()
    return host
  }

  private func requirePreparation(_ generation: UUID) throws {
    try Task.checkCancellation()
    try lock.withLock {
      guard preparationGeneration == generation else { throw CancellationError() }
    }
  }

  func cancelPlanPreparation() {
    lock.withLock {
      preparationGeneration = UUID()
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
    }
  }

  private func accountClient() throws -> AuthenticatedEngineXPCSubmitter {
    let configuration = try loadConfiguration()
    return try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
  }

  func inspectRecoveryAccount() async throws -> RecoveryAccountReply? {
    // Registration alone does not authenticate the running service. An older
    // service may reject this app; upgrade it only after the owner authorizes.
    guard await helperProbe().isCurrent else { return nil }
    let reply: RecoveryAccountReply
    if let recoveryAccountInspector {
      reply = try await recoveryAccountInspector()
    } else {
      reply = try await accountClient().recoveryAccount(action: "inspect")
    }
    return reply.target == nil ? nil : reply
  }

  func prepareRecoveryAccount(ticket: String, username: String, password: Data) async throws
    -> RecoveryAccountReply
  {
    try await accountClient().recoveryAccount(
      action: "prepare", ticket: ticket, username: username, password: password)
  }

  func prepareRecoveryHandoff(ticket: String) async throws -> RecoveryAccountReply {
    try await accountClient().recoveryAccount(action: "handoff", ticket: ticket)
  }

  func finalizeRecoveryAccount(ticket: String, password: Data) async throws -> RecoveryAccountReply
  {
    try await accountClient().recoveryAccount(
      action: "finalize", ticket: ticket, password: password)
  }

  func openStartupDisk() -> Bool {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/System/Library/PreferencePanes/StartupDisk.prefPane"))
  }

  var payloadPrefetchRequired: Bool { true }

  var payloadPrefetchState: PayloadPrefetchState {
    prefetch.currentState()
  }
  // MARK: Fail-closed gates

  var installationBlocked: Bool {
    lock.withLock {
      guard let hostInspection else {
        return true
      }
      if case .blocked = hostInspection.eligibility {
        return true
      }
      return false
    }
  }

  var engineSupported: Bool {
    lock.withLock { engineInspection?.support == .supported }
  }

  var hasApprovedPlan: Bool {
    lock.withLock {
      preparedPlan != nil && planApproval != nil && releaseConfiguration != nil
    }
  }

  var helperStatus: HelperDisplay {
    InstallerHelperSetup.display
  }

  // MARK: Inspection

  func inspect() async throws -> HostDisplay {
    try await prefetch.waitForRetirement()
    let host = try await inspectCurrentHost()

    var engine: ValidatedEngineTranscript?
    var transcript: Data?
    var engineFailure: String?
    var knownInstallations = [NativeKnownInstallation]()
    do {
      let inspection = try await inspector.inspect(host: host, metadata: nil)
      guard
        inspection.validated.deviceIdentifier == host.identity.deviceIdentifier
      else {
        engineFailure = PlainLanguage.engineIdentityMismatch
        throw InstallerAppError.hostChanged
      }
      engine = inspection.validated
      transcript = inspection.transcript
      knownInstallations = inspection.knownInstallations
    } catch InstallerAppError.hostChanged {
      // engineFailure already set above.
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      engineFailure =
        "The disk compatibility check failed. Installation is unavailable. Details: \(String(describing: error))"
    }

    lock.withLock {
      hostInspection = host
      engineInspection = engine
      engineInspectionTranscript = transcript
      engineInspectionFailure = engineFailure
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
    }
    cancelPayloadPrefetch()

    var unsupportedModel: UnsupportedModelDisplay?
    let modelRefused =
      AppleSiliconHostInspector.isExplicitlyUnsupported(host.identity.deviceIdentifier)
      || engine?.support == .unsupported
    if modelRefused {
      unsupportedModel = UnsupportedModelDisplay(
        deviceIdentifier: host.identity.deviceIdentifier,
        modelIdentifier: host.identity.model,
        supportedDeviceIdentifiers: await supportedDeviceIdentifiers()
      )
    }

    return display(
      host: host, engine: engine, engineFailure: engineFailure,
      unsupportedModel: unsupportedModel, knownInstallations: knownInstallations)
  }

  /// The signed catalog's model list for the unsupported-Mac message. Any
  /// failure (offline, unsigned, rolled back) just leaves the list out.
  private func supportedDeviceIdentifiers() async -> [String]? {
    guard let configuration = try? loadConfiguration(),
      let workspace = try? installerWorkspace()
    else {
      return nil
    }
    let channel = ReleaseChannelPreference().resolve(configuration: configuration)
    // Unreadable or unsafe rollback state shows no list rather than skipping
    // the rollback check.
    let previouslyAccepted: AcceptedCatalogIdentity?
    do {
      previouslyAccepted = try AcceptedCatalogIdentityStore(
        directory: workspace.state,
        channel: channel
      ).load()
    } catch {
      return nil
    }
    return try? await InstallerReleaseAssetCoordinator().supportedDeviceIdentifiers(
      configuration: configuration,
      channel: channel,
      validationTime: Date(),
      previouslyAcceptedCatalog: previouslyAccepted
    )
  }

  /// Every channel's catalog, checked side by side for this Mac. A channel
  /// whose rollback state cannot be read counts as unverifiable rather than
  /// skipping the rollback check.
  func channelAvailability() async -> [ReleaseChannel: ReleaseChannelAvailability] {
    guard let host = lock.withLock({ hostInspection }) else { return [:] }
    let deviceIdentifier = host.identity.deviceIdentifier
    let everyChannelFailed = { (error: any Error) in
      Dictionary(
        uniqueKeysWithValues: ReleaseChannel.allCases.map {
          ($0, ReleaseChannelAvailability(checkError: error))
        })
    }
    let configuration: InstallerReleaseConfiguration
    do {
      configuration = try loadConfiguration()
    } catch {
      return everyChannelFailed(error)
    }
    // A sealed catalog answers for every channel alike, so it says nothing
    // about what each channel offers.
    guard configuration.sealedCatalogDocuments == nil else { return [:] }
    let stateDirectory: URL
    do {
      stateDirectory = try installerWorkspace().state
    } catch {
      return everyChannelFailed(error)
    }
    return await withTaskGroup(
      of: (ReleaseChannel, ReleaseChannelAvailability).self
    ) { group in
      for channel in ReleaseChannel.allCases {
        group.addTask {
          let previouslyAccepted: AcceptedCatalogIdentity?
          do {
            previouslyAccepted = try AcceptedCatalogIdentityStore(
              directory: stateDirectory,
              channel: channel
            ).load()
          } catch {
            return (channel, ReleaseChannelAvailability(checkError: error))
          }
          return (
            channel,
            await InstallerReleaseAssetCoordinator().availability(
              configuration: configuration,
              channel: channel,
              deviceIdentifier: deviceIdentifier,
              validationTime: Date(),
              previouslyAcceptedCatalog: previouslyAccepted
            )
          )
        }
      }
      var result = [ReleaseChannel: ReleaseChannelAvailability]()
      for await (channel, availability) in group {
        result[channel] = availability
      }
      return result
    }
  }

  // MARK: Plan preparation

  func preparePlan(
    auroraBytes: UInt64?,
    progress: @escaping @Sendable (AssetProgressUpdate) -> Void
  ) async throws -> PlanPreparationDisplay {
    try await preparePlan(
      auroraBytes: auroraBytes, preservingStage1: false, progress: progress)
  }

  func preparePreservedReinstallPlan(
    progress: @escaping @Sendable (AssetProgressUpdate) -> Void
  ) async throws -> PlanPreparationDisplay {
    try await preparePlan(
      auroraBytes: nil, preservingStage1: true, progress: progress)
  }

  private func preparePlan(
    auroraBytes: UInt64?, preservingStage1: Bool,
    progress: @escaping @Sendable (AssetProgressUpdate) -> Void
  ) async throws -> PlanPreparationDisplay {
    try Task.checkCancellation()
    let (host, hasTranscript, generation) = lock.withLock {
      preparationGeneration = UUID()
      let retained = (hostInspection, engineInspectionTranscript != nil)
      planReview = nil
      preparedPlan = nil
      planApproval = nil
      releaseConfiguration = nil
      return (retained.0, retained.1, preparationGeneration)
    }

    guard let host, hasTranscript else {
      throw InstallerAppError.inspectionRequired
    }
    try await prefetch.waitForRetirement()
    try requirePreparation(generation)

    progress(AssetProgressUpdate(stage: .fetchingCatalog))

    let configuration = try loadConfiguration()
    let workspace = try installerWorkspace()
    let channel = ReleaseChannelPreference().resolve(configuration: configuration)
    let catalogStore = AcceptedCatalogIdentityStore(
      directory: workspace.state,
      channel: channel
    )
    let previouslyAcceptedCatalog = try catalogStore.load()
    let validationTime = Date()

    let collector = StagingProgressCollector(publish: progress)
    let release = try await InstallerReleaseAssetCoordinator()
      .prepareRelease(
        InstallerReleasePreparationRequest(
          host: host,
          configuration: configuration,
          channel: channel,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog,
          installerVersion: InstallerVersion.current(),
          stagingDirectory: workspace.staging
        ),
        progress: { event in
          collector.record(event)
        },
        previouslyPrepared: lock.withLock { reusableAssets },
        includePayload: false
      )
    try requirePreparation(generation)
    try selection.requireMatchingProfile(release.assets.installer.installationProfile)
    try lock.withLock {
      guard preparationGeneration == generation, !Task.isCancelled else {
        throw CancellationError()
      }
      reusableAssets = release.assets
      selectedLane = channel.rawValue
    }
    try catalogStore.store(release.assets.catalogIdentity)
    Self.discardStaleDownloads(
      in: workspace.staging, keeping: release.assets.metadata.fileURL.deletingLastPathComponent())
    // The payload is pinned by the verified catalog and does not depend on the
    // plan, so it downloads while the engine checks the Mac and the owner picks
    // a size. The session cancels it if this preparation fails.
    try beginPayloadPrefetch(release.assets.payload, generation: generation)
    try await prefetch.waitForRetirement()
    try requirePreparation(generation)

    progress(
      AssetProgressUpdate(stage: .inspectingEngine, rows: collector.rows())
    )

    // Sampled before native inspection reads free space, so a download that moves on
    // during inspection only makes the reserve more cautious.
    let payloadBytesOnDisk = prefetch.bytesOnDisk(for: release.assets.payload)
    let planningReserve = release.assets.planningReserveBytes(
      payloadBytesOnDisk: payloadBytesOnDisk)
    let freshHost = try await inspectCurrentHost()
    try requirePreparation(generation)
    guard freshHost.identity == host.identity else { throw InstallerAppError.hostChanged }
    let signedInspection = try await inspector.inspect(
      host: freshHost, metadata: release.assets.metadata)
    try requirePreparation(generation)
    guard
      signedInspection.validated.deviceIdentifier
        == host.identity.deviceIdentifier,
      signedInspection.validated.support == .supported,
      let inventory = signedInspection.validated.inventory,
      let geometry = signedInspection.displayGeometry
    else {
      throw InstallerPlanPreparationError.unsupportedDevice(
        host.identity.deviceIdentifier
      )
    }

    progress(AssetProgressUpdate(stage: .planning, rows: collector.rows()))

    let existing = Self.existingInstalls(
      in: signedInspection.validated,
      knownInstallations: signedInspection.knownInstallations)
    let recommendation: InstallerAllocationRecommendation
    if preservingStage1 {
      let sources = Set(existing.map(\.sourceIdentifier))
      let candidates = inventory.candidates.filter {
        $0.kind == "reinstall" && sources.contains($0.sourceIdentifier)
      }
      guard candidates.count == 1, let candidate = candidates.first else {
        throw InstallerPlanPreparationError.preservedReinstallUnavailable
      }
      recommendation = try InstallerAllocationRecommendation(preserved: candidate)
    } else {
      if !existing.isEmpty { return .existingInstallChoice(existing) }
      recommendation = try InstallerAllocationRecommendation(
        inventory: inventory,
        targetBytes: auroraBytes ?? InstallerAllocationRecommendation.balancedTargetBytes,
        reservedBytes: planningReserve,
        snapshotConstraint: {
          APFSSnapshotInspector().constraint(in: host.storage)
        }
      )
    }
    let candidate = recommendation.candidate
    let requestedLengthBytes = recommendation.requestedLengthBytes

    let prepared = try await InstallerPlanPreparationCoordinator()
      .prepareExecution(
        InstallerPlanPreparationRequest(
          host: host,
          release: release,
          configuration: configuration,
          inspectionTranscript: signedInspection.transcript,
          candidate: candidate,
          requestedLengthBytes: requestedLengthBytes,
          validationTime: validationTime,
          previouslyAcceptedCatalog: previouslyAcceptedCatalog
        )
      )

    try lock.withLock {
      guard preparationGeneration == generation, !Task.isCancelled else {
        throw CancellationError()
      }
      preparedPlan = prepared
      planReview = prepared.review
      releaseConfiguration = configuration
    }

    return .plan(
      Self.planDisplay(
        review: prepared.review, host: freshHost, recommendation: recommendation,
        reservedBytes: planningReserve,
        geometry: geometry,
        release:
          "\(channel.rawValue.capitalized) · \(release.assets.payload.fileURL.lastPathComponent)"
      ))
  }

  // MARK: Approval

  /// The confirmation is rebuilt field by field from the retained review — the
  /// same values the Exact plan panel rendered — and `approve(confirming:)`
  /// re-checks every one of them.
  func approve() throws {
    let review = lock.withLock { planReview }

    guard let review else {
      throw InstallerAppError.approvalUnavailable
    }
    let confirmation = InstallerOwnerPlanConfirmation(
      bindingDigest: review.identity.bindingDigest,
      planDigest: review.plan.planDigest,
      deviceIdentifier: review.plan.deviceIdentifier,
      storeIdentifier: review.plan.storeIdentifier,
      sourceIdentifier: review.plan.sourceIdentifier,
      offsetBytes: review.plan.offsetBytes,
      lengthBytes: review.plan.lengthBytes,
      requiredHumanSteps: review.plan.requiredHumanSteps
    )
    do {
      let approval = try review.approve(confirming: confirmation)
      lock.withLock { planApproval = approval }
    } catch {
      lock.withLock { planApproval = nil }
      throw error
    }
  }

  func discardApproval() {
    lock.withLock { planApproval = nil }
  }

  // MARK: Helper

  func refreshHelperStatus() -> HelperDisplay {
    helperStatus
  }

  func probeHelperStatus() async -> HelperDisplay {
    await helperProbe()
  }

  func ensureHelper(
    _ authorization: MachineOwnerAuthorization, reenablingSwitchedOff: Bool
  ) async throws {
    try await InstallerHelperSetup.ensure(
      authorization, reenablingSwitchedOff: reenablingSwitchedOff)
  }

  // MARK: Shutdown

  /// The graceful route: the same Apple Event the Apple menu sends. Apps with
  /// unsaved work can still object, and nothing here needs the privileged
  /// helper.
  func requestShutdown() -> Bool {
    let target = NSAppleEventDescriptor(
      bundleIdentifier: "com.apple.loginwindow"
    )
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAEShutDown),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    do {
      _ = try event.sendEvent(options: [.noReply], timeout: 3)
      return true
    } catch {
      return false
    }
  }

  func requestRestart() -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAERestart),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    do {
      _ = try event.sendEvent(options: [.noReply], timeout: 3)
      return true
    } catch {
      return false
    }
  }

  func setEncryptLinuxDisk(_ encrypt: Bool) {
    lock.withLock { encryptLinuxDisk = buildProfile.allowsEncryption ? encrypt : false }
  }

  func cancelPayloadPrefetch() {
    lock.withLock { plannedPayload = nil }
    prefetch.cancel()
  }

  func cancelPayloadPrefetchOnQuit() {
    cancelPlanPreparation()
    lock.withLock { plannedPayload = nil }
    prefetch.cancelAndDrainForQuit()
  }

  func restartPayloadPrefetch() {
    guard let payload = lock.withLock({ plannedPayload }) else { return }
    // A failed or cancelled download of the same digest starts afresh; a
    // running one is left alone.
    prefetch.begin(payload: payload)
  }

  func prefetchPayload(
    progress: @escaping @Sendable (PayloadPrefetchState) -> Void
  ) async throws {
    try await prefetch.waitUntilVerified(progress: progress)
  }

  func waitUntilPayloadVerified() async throws {
    try await prefetch.waitUntilVerified(progress: { _ in })
  }

  private func beginPayloadPrefetch(_ payload: StagedInstallerArtifact, generation: UUID) throws {
    try lock.withLock {
      guard preparationGeneration == generation, !Task.isCancelled else {
        throw CancellationError()
      }
      plannedPayload = payload
      prefetch.begin(payload: payload)
    }
  }

  // MARK: Execution

  static func pendingJobStore() throws -> PendingInstallerJobStore {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { throw InstallerAppError.workspaceUnavailable }
    let base = support.appendingPathComponent(
      InstallerBuildProfile.current.workspaceName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: base.path) {
      try FileManager.default.createDirectory(
        at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    return PendingInstallerJobStore(directory: base)
  }

  func hasPendingInstallation() throws -> Bool {
    try Self.pendingJobStore().load() != nil
  }

  func resumeInstallation(journal: @escaping @Sendable (Data) -> Void) async throws
    -> InstallerRestorationResult
  {
    let store = try Self.pendingJobStore()
    guard let hint = try store.load(), hint.ticket.selection == selection else {
      throw InstallerJobError.identityMismatch
    }
    let configuration = try loadConfiguration()
    let client = try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement,
      journalProgress: journal)
    // A helper the installer package just replaced may still be starting.
    try await client.waitForHelper()
    // Observing is read-only, so a job an earlier build of this installer
    // started can be looked up as it is. Continuing it waits for the
    // machine-owner password; see retryPendingRecovery.
    let snapshot = try await client.observeJob(hint, otherBuild: true)
    if snapshot.recoveryRetryAvailable {
      _ = try requireMatchingJobDevice(snapshot)
      return .requiresRecoveryAuthorization
    }
    if let failure = snapshot.initialFailureWithoutDiskChanges {
      try store.clear(ifMatching: hint)
      return .failedBeforeDiskChanges(failure)
    }
    let bytes: Data
    let handoff: InstallConfHandoff
    do { (bytes, handoff) = try snapshot.requireResult() } catch let error
      as EngineXPCSubmissionError where error == .machineOwnerCredentialsRejected
    {
      guard snapshot.recoveryAttempt == nil else { throw InstallerJobError.interrupted }
      try store.clear()
      throw error
    }
    let completion = try completionFromJob(snapshot, bytes: bytes, handoff: handoff)
    try store.clear()
    return .completed(completion)
  }

  func pendingInstallationOptions() async -> InstallerPendingOptions {
    guard let store = try? Self.pendingJobStore(), let hint = try? store.load(),
      hint.ticket.selection == selection, let configuration = try? loadConfiguration(),
      let client = try? AuthenticatedEngineXPCSubmitter(
        machServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
    else { return InstallerPendingOptions() }
    do {
      try await client.waitForHelper(attempts: 10)
      let snapshot = try await client.jobStatus(hint, otherBuild: true)
      if snapshot.recoveryRetryAvailable { _ = try requireMatchingJobDevice(snapshot) }
      return InstallerPendingOptions(
        retry: snapshot.recoveryRetryAvailable, startOver: snapshot.startOverAvailable == true)
    } catch let error as InstallerJobError where error == .unavailable {
      // The helper keeps no record of this job: only the hint is left.
      return InstallerPendingOptions(startOver: true)
    } catch {
      return InstallerPendingOptions()
    }
  }

  func startOverPendingInstallation() async throws {
    let store = try Self.pendingJobStore()
    guard let hint = try store.load(), hint.ticket.selection == selection else {
      throw InstallerJobError.identityMismatch
    }
    let configuration = try loadConfiguration()
    let client = try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
    // The helper decides whether the job may be set aside, whichever build
    // of this installer started it, and the hint is then cleared.
    try await client.abandonJob(hint, store: store, otherBuild: true)
  }

  private func requireMatchingJobDevice(_ snapshot: InstallerJobSnapshot) throws
    -> InstallerJobPlanIdentity
  {
    let host = try AppleSiliconHostInspector().inspect()
    guard let identity = snapshot.plan,
      identity.deviceIdentifier == host.identity.deviceIdentifier
    else { throw InstallerJobError.identityMismatch }
    lock.withLock { hostInspection = host }
    return identity
  }

  private func completionFromJob(
    _ snapshot: InstallerJobSnapshot, bytes: Data, handoff: InstallConfHandoff
  ) throws -> CompletionDisplay {
    let identity = try requireMatchingJobDevice(snapshot)
    let transcript = try AppleInstallerTrustCore().validateEngineTranscript(bytes)
    let progress = try InstallerExecutionProgress(observing: identity, transcript: transcript)
    return Self.completionDisplay(progress, installConf: handoff)
  }

  private func retryPendingRecovery(
    authorization: MachineOwnerAuthorization, journal: @escaping @Sendable (Data) -> Void
  ) async throws -> CompletionDisplay {
    let store = try Self.pendingJobStore()
    guard let hint = try store.load(), hint.ticket.selection == selection else {
      throw InstallerJobError.identityMismatch
    }
    let configuration = try loadConfiguration()
    let client = try AuthenticatedEngineXPCSubmitter(
      machServiceName: configuration.helperMachServiceName,
      helperCodeSigningRequirement: configuration.helperCodeSigningRequirement,
      journalProgress: journal)
    // The machine-owner password was checked before this point, and the
    // helper checks it again. A job an earlier build of this installer
    // started is then bound to this build's helper, which installing the
    // newer build put in place.
    let snapshot = try await client.retryRecoveryJob(
      hint, store: store, authorization: authorization, adoptingOtherBuild: true)
    let (bytes, handoff) = try snapshot.requireResult()
    let completion = try completionFromJob(snapshot, bytes: bytes, handoff: handoff)
    try store.clear()
    discardDownloadsIfFinished(completion.nextAction)
    return completion
  }

  func execute(
    operation: InstallOperationKind,
    authorization: MachineOwnerAuthorization,
    encryptLinuxDisk: Bool,
    journal: @escaping @Sendable (Data) -> Void
  ) async throws -> CompletionDisplay {
    try await execute(
      operation: operation, authorization: authorization, encryptLinuxDisk: encryptLinuxDisk,
      journal: journal, preparation: { _ in })
  }

  func execute(
    operation: InstallOperationKind,
    authorization: MachineOwnerAuthorization,
    encryptLinuxDisk: Bool,
    journal: @escaping @Sendable (Data) -> Void,
    preparation: @escaping @Sendable (String) -> Void
  ) async throws -> CompletionDisplay {
    if operation == .retryRecoveryAuthorization {
      return try await retryPendingRecovery(authorization: authorization, journal: journal)
    }
    guard buildProfile.allowsEncryption || !encryptLinuxDisk else {
      throw NSError(
        domain: "AuroraPrivateTest", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "This private M3 test supports plain installation only."
        ]
      )
    }
    let executionStarted = ProcessInfo.processInfo.systemUptime
    let (prepared, approval, configuration, host) = lock.withLock {
      (preparedPlan, planApproval, releaseConfiguration, hostInspection)
    }

    guard let prepared, let approval, let configuration, let host else {
      throw InstallerAppError.approvalUnavailable
    }

    // Re-inspection identity match: the Mac that is about to be written to
    // must still be the Mac the plan was bound to.
    let currentHost = try AppleSiliconHostInspector().inspect()
    guard
      currentHost.identity.deviceIdentifier == host.identity.deviceIdentifier
    else {
      throw InstallerAppError.hostChanged
    }

    let workspace = try installerWorkspace()
    let lane = lock.withLock { selectedLane }
    let pendingStore = try Self.pendingJobStore()
    let jobContext = InstallerJobExecutionContext(
      bindingDigest: prepared.review.identity.bindingDigest, selection: selection,
      store: pendingStore,
      installConf: try InstallConf(encrypt: encryptLinuxDisk, lane: lane),
      preparation: preparation)
    let coordinator = InstallerExecutionCoordinator()
    let progress: InstallerExecutionProgress
    do {
      switch operation {
      case .install:
        progress = try await coordinator.execute(
          prepared,
          approval: approval,
          configuration: configuration,
          handoffDirectory: workspace.handoff,
          machineOwnerAuthorization: authorization,
          journalProgress: journal,
          jobContext: jobContext
        )
      case .retryRecoveryAuthorization:
        progress = try await coordinator.retryRecoveryAuthorization(
          prepared,
          approval: approval,
          configuration: configuration,
          handoffDirectory: workspace.handoff,
          machineOwnerAuthorization: authorization,
          journalProgress: journal,
          jobContext: jobContext
        )
      }
    } catch let EngineXPCSubmissionError.engineFailed(notice) {
      EngineFailureUserLog.write(notice, operation: String(describing: operation))
      throw EngineXPCSubmissionError.engineFailed(notice)
    }
    let installConf = jobContext.installConfHandoff ?? .notRecorded
    let handoffOperation: EngineHandoffOperation =
      operation == .retryRecoveryAuthorization ? .retryRecoveryAuthorization : .install
    if InstallConfRecordPolicy.shouldRecord(
      operation: handoffOperation, nextAction: progress.nextAction)
    {
      if operation == .install {
        InstallationTimingHistory.recordCompleted(
          seconds: ProcessInfo.processInfo.systemUptime - executionStarted)
      }
    }
    try pendingStore.clear()
    discardDownloadsIfFinished(progress.nextAction)
    return Self.completionDisplay(progress, installConf: installConf)
  }

  // MARK: Downloads

  /// Once the macOS part of an installation is done, Recovery reads its payload
  /// from the installation's own volume (AuraPayloads), so no downloaded image
  /// is needed. Keeping them took several GB from every later installation.
  private func discardDownloadsIfFinished(_ next: InstallerNextAction) {
    guard Self.finishedOnMac(next),
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return }
    lock.withLock { reusableAssets = nil }
    Self.discardDownloads(
      productBase: support.appendingPathComponent(buildProfile.workspaceName, isDirectory: true))
  }

  static func finishedOnMac(_ next: InstallerNextAction) -> Bool {
    [.enterRecovery, .attachInstallationMedia, .verifyInstalledSystem].contains(next)
  }

  /// Removes every system's downloaded releases. A later installation downloads
  /// and verifies its image again.
  static func discardDownloads(productBase: URL) {
    let fm = FileManager.default
    guard
      let profiles = try? fm.contentsOfDirectory(at: productBase, includingPropertiesForKeys: nil)
    else { return }
    for profile in profiles {
      discardStaleDownloads(
        in: profile.appendingPathComponent("staging", isDirectory: true), keeping: nil)
    }
  }

  /// Removes a system's downloaded releases other than the one being prepared:
  /// an earlier build's or channel's image only takes space Linux could have.
  static func discardStaleDownloads(in staging: URL, keeping current: URL?) {
    let fm = FileManager.default
    let kept = current?.standardizedFileURL.path
    guard let entries = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
    else { return }
    for entry in entries where entry.standardizedFileURL.path != kept {
      try? fm.removeItem(at: entry)
    }
  }

  // MARK: Display mapping

  private func display(
    host: AppleSiliconHostInspection,
    engine: ValidatedEngineTranscript?,
    engineFailure: String?,
    unsupportedModel: UnsupportedModelDisplay?,
    knownInstallations: [NativeKnownInstallation]
  ) -> HostDisplay {
    let blocked: Bool
    if case .blocked = host.eligibility {
      blocked = true
    } else {
      blocked = false
    }

    let existing = Self.existingInstalls(in: engine, knownInstallations: knownInstallations)
    let space = existing.isEmpty ? Self.spaceCheck(engine: engine, host: host) : nil
    let chipAndFreeSpace =
      "\(host.identity.chip) · \(PlainLanguage.bytes(host.storage.containerFreeBytes)) free"
    var chipAndSpace = chipAndFreeSpace
    if case .fits(let maximumBytes) = space {
      chipAndSpace += " · up to \(PlainLanguage.bytes(maximumBytes)) for Aurora"
    }

    return HostDisplay(
      chipAndSpace: chipAndSpace,
      chipAndFreeSpace: chipAndFreeSpace,
      supported: !blocked && engine?.support == .supported,
      blockingReason: blockingReason(host: host, engineFailure: engineFailure),
      existingInstalls: existing,
      spaceShortfall: space?.shortfall,
      unsupportedModel: unsupportedModel,
      powerButtonGuide: MacPowerButtonGuide(
        deviceIdentifier: host.identity.deviceIdentifier, modelIdentifier: host.identity.model)
    )
  }

  private enum SpaceCheck {
    case fits(maximumBytes: UInt64)
    case shortfall(InstallerAllocationRecommendationError)

    var shortfall: InstallerAllocationRecommendationError? {
      if case .shortfall(let error) = self { error } else { nil }
    }
  }

  /// Runs the allocation recommendation on the native inspection's inventory, so
  /// a disk that cannot hold Aurora is reported before the catalog is fetched
  /// or the release downloaded. The handoff reserve is not known yet, so this
  /// can only be more generous than the check after the download.
  private static func spaceCheck(
    engine: ValidatedEngineTranscript?,
    host: AppleSiliconHostInspection
  ) -> SpaceCheck? {
    guard engine?.support == .supported, let inventory = engine?.inventory else {
      return nil
    }
    do {
      let recommendation = try InstallerAllocationRecommendation(
        inventory: inventory,
        snapshotConstraint: { APFSSnapshotInspector().constraint(in: host.storage) }
      )
      return .fits(maximumBytes: recommendation.maximumBytes)
    } catch let error as InstallerAllocationRecommendationError {
      return .shortfall(error)
    } catch {
      return nil
    }
  }

  /// The native report is independent of the selected profile and minimum
  /// image size. Keep legacy candidates too, without changing their contract.
  static func existingInstalls(
    in engine: ValidatedEngineTranscript?,
    knownInstallations: [NativeKnownInstallation] = []
  ) -> [ExistingInstallDisplay] {
    var result = (engine?.inventory?.candidates ?? [])
      .filter { $0.kind == "replace" }
      .map { existing in
        ExistingInstallDisplay(
          sourceIdentifier: existing.sourceIdentifier,
          sizeDescription: PlainLanguage.bytes(existing.lengthBytes)
        )
      }
    var sources = Set(result.map(\.sourceIdentifier))
    for known in knownInstallations where sources.insert(known.sourceIdentifier).inserted {
      result.append(
        ExistingInstallDisplay(
          sourceIdentifier: known.sourceIdentifier,
          sizeDescription: PlainLanguage.bytes(known.lengthBytes), partial: known.partial))
    }
    return result
  }

  private func blockingReason(
    host: AppleSiliconHostInspection,
    engineFailure: String?
  ) -> String? {
    if case .blocked(let reason) = host.eligibility {
      return reason
    }
    return engineFailure
  }

  static func planDisplay(
    review: InstallerPlanReview,
    host: AppleSiliconHostInspection,
    recommendation: InstallerAllocationRecommendation,
    reservedBytes: UInt64 = 0,
    geometry: NativeDiskDisplayGeometry? = nil,
    release: String
  ) -> PlanDisplay {
    let length = review.plan.lengthBytes
    let total =
      geometry?.diskTotalBytes
      ?? (review.plan.candidateKind == "free"
        ? host.storage.containerSizeBytes + recommendation.candidate.lengthBytes
        : max(host.storage.containerSizeBytes, length))
    let source: PlanAllocationSource
    switch review.plan.candidateKind {
    case "reinstall": source = .preservedInstall
    case "free": source = .freeExtent
    default:
      let sourceStore = geometry?.macOSStoreIdentifier ?? host.storage.physicalStoreIdentifier
      if review.plan.sourceIdentifier == sourceStore {
        source = .macOSResize
      } else {
        source = .otherContainerResize
      }
    }
    let otherAllocated = geometry?.otherAllocatedBytes ?? 0
    let otherAfter: UInt64
    if source == .preservedInstall {
      otherAfter = otherAllocated - min(otherAllocated, length)
    } else {
      otherAfter = otherAllocated
    }
    let sourceName = (geometry?.partitionNames[review.plan.sourceIdentifier]).flatMap {
      $0.isEmpty ? nil : String($0.prefix(128))
    }
    let targetDescription: String
    switch source {
    case .freeExtent: targetDescription = "Internal storage · Use free space"
    case .macOSResize: targetDescription = "Internal storage · Resize macOS"
    case .otherContainerResize:
      targetDescription = "Internal storage · Resize " + (sourceName ?? "another APFS container")
    case .preservedInstall:
      targetDescription = "Existing Aurora installation · Reset without resizing"
    }

    return PlanDisplay(
      diskTotalBytes: total,
      auroraBytes: length,
      bindingDigest: review.identity.bindingDigest,
      isResizable: !["replace", "reinstall"].contains(review.plan.candidateKind),
      minimumBytes: recommendation.minimumBytes,
      maximumBytes: recommendation.maximumBytes,
      releaseDescription: release,
      targetDescription: targetDescription,
      fixedMacOSBytes: source == .macOSResize ? nil : host.storage.containerSizeBytes,
      macOSFreeBeforeAllocationBytes:
        review.plan.candidateKind == "resize"
        && recommendation.candidate.sourceIdentifier == host.storage.physicalStoreIdentifier
        ? host.storage.containerFreeBytes - min(host.storage.containerFreeBytes, reservedBytes)
        : nil,
      recommendedAuroraBytes: source == .preservedInstall
        ? nil : recommendation.candidate.recommendedInstallBytes,
      allocationSource: source,
      baselineMacOSBytes: geometry?.macOSBytes,
      otherAllocatedBytes: otherAfter
    )
  }

  static func completionDisplay(
    _ progress: InstallerExecutionProgress,
    installConf: InstallConfHandoff = .recorded
  ) -> CompletionDisplay {
    let handoff: HandoffDisplay?
    let warning = PlainLanguage.installConfWarning(installConf)
    switch progress.nextAction {
    case .enterRecovery:
      handoff = HandoffDisplay(
        headline: PlainLanguage.recoveryHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps),
        warning: warning
      )
    case .attachInstallationMedia:
      handoff = HandoffDisplay(
        headline: PlainLanguage.mediaHeadline,
        steps: PlainLanguage.recoverySteps(for: progress.requiredHumanSteps),
        warning: warning
      )
    default:
      handoff = nil
    }

    return CompletionDisplay(
      nextAction: progress.nextAction,
      headline: progress.nextAction == .verifyInstalledSystem
        ? PlainLanguage.doneHeadline : PlainLanguage.recoveryHeadline,
      subheadline: PlainLanguage.nextActionMessage(
        progress.nextAction, installConf: installConf),
      verified: PlainLanguage.doneVerifiedRows,
      handoff: handoff
    )
  }

  // MARK: Workspace

  private func installerWorkspace() throws
    -> (staging: URL, scratch: URL, state: URL, handoff: URL)
  {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw InstallerAppError.workspaceUnavailable
    }
    let productBase = applicationSupport.appendingPathComponent(
      buildProfile.workspaceName, isDirectory: true)
    try createPrivateDirectoryIfMissing(productBase)
    let base = productBase.appendingPathComponent(selection.profileID, isDirectory: true)
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    let scratch = base.appendingPathComponent("scratch", isDirectory: true)
    let state = base.appendingPathComponent("state", isDirectory: true)
    let handoff = base.appendingPathComponent("handoff", isDirectory: true)
    try createPrivateDirectoryIfMissing(base)
    try createPrivateDirectoryIfMissing(staging)
    try createPrivateDirectoryIfMissing(scratch)
    try createPrivateDirectoryIfMissing(state)
    try createPrivateDirectoryIfMissing(handoff)
    return (staging, scratch, state, handoff)
  }

  private func createPrivateDirectoryIfMissing(_ directory: URL) throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      return
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }
}

/// Collects `ArtifactStagingProgress` events by role and republishes them as
/// preparing-screen rows.
private final class StagingProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var latest = [String: ArtifactStagingProgress]()
  private let publish: @Sendable (AssetProgressUpdate) -> Void

  init(publish: @escaping @Sendable (AssetProgressUpdate) -> Void) {
    self.publish = publish
  }

  func record(_ event: ArtifactStagingProgress) {
    let snapshot = lock.withLock { () -> [AssetProgressRow] in
      latest[event.role] = event
      return AssetProgressRow.rows(from: latest)
    }
    publish(AssetProgressUpdate(stage: .downloading, rows: snapshot))
  }

  func rows() -> [AssetProgressRow] {
    lock.withLock { AssetProgressRow.rows(from: latest) }
  }
}
