#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  protocol NativeFirmwarePreparing: Sendable {
    func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL?
  }

  /// One helper-owned copy per sealed recipe, outside disposable package imports.
  /// The helper's work gate serializes access. Neither the recipe nor these paths
  /// are supplied by the GUI. Interrupted ranges survive a retry; published files
  /// are authenticated again before they can be reused.
  struct NativeFirmwarePreparer: NativeFirmwarePreparing {
    private let expectedOwnerID: uid_t
    private let extractRecipe: @Sendable (FirmwareExtractionPlan, URL, URL) async throws -> Void

    init(expectedOwnerID: uid_t = 0) {
      self.expectedOwnerID = expectedOwnerID
      extractRecipe = { plan, output, cache in
        _ = try await FirmwareExtractor().extractOrResume(
          plan, to: output, cacheDirectory: cache)
      }
    }

    init(
      expectedOwnerID: uid_t,
      extract: @escaping @Sendable (FirmwareExtractionPlan, URL, URL) async throws -> Void
    ) {
      self.expectedOwnerID = expectedOwnerID
      extractRecipe = extract
    }

    func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
      // Other boards retain their existing preparation until their native recipe
      // has its own qualification. Never apply this board's inputs to another Mac.
      guard NativePeripheralInputPath.needsPreparation(deviceIdentifier: deviceIdentifier)
      else { return nil }
      return try await extract(
        FirmwareExtractionPlan.bundled(for: deviceIdentifier), in: workingDirectory)
    }

    /// The authenticated files of a sealed recipe, extracted (or verified
    /// again and reused) under `workingDirectory/native-firmware/<recipe>/raw`.
    func extract(_ plan: FirmwareExtractionPlan, in workingDirectory: URL) async throws -> URL {
      try validateDirectory(workingDirectory)
      let namespace = workingDirectory.appendingPathComponent("native-firmware", isDirectory: true)
      try ensureDirectory(namespace)
      let recipe = namespace.appendingPathComponent(plan.recipeSHA256, isDirectory: true)
      try ensureDirectory(recipe)
      let output = recipe.appendingPathComponent("raw", isDirectory: true)
      let cache = recipe.appendingPathComponent("ranges", isDirectory: true)
      try await extractRecipe(plan, output, cache)
      try validateDirectory(output)
      return output
    }

    private func ensureDirectory(_ url: URL) throws {
      if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
        throw InstallerJobError.unsafeState
      }
      try validateDirectory(url)
    }

    private func validateDirectory(_ url: URL) throws {
      var info = stat()
      guard url.isFileURL, lstat(url.path, &info) == 0,
        info.st_mode & S_IFMT == S_IFDIR, info.st_uid == expectedOwnerID,
        info.st_mode & 0o077 == 0
      else { throw InstallerJobError.unsafeState }
    }
  }
#endif
