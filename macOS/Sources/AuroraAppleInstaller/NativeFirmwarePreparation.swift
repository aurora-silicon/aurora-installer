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
    private let extract: @Sendable (FirmwareExtractionPlan, URL, URL) async throws -> Void

    init() {
      expectedOwnerID = 0
      extract = { plan, output, cache in
        _ = try await FirmwareExtractor().extractOrResume(
          plan, to: output, cacheDirectory: cache)
      }
    }

    init(
      expectedOwnerID: uid_t,
      extract: @escaping @Sendable (FirmwareExtractionPlan, URL, URL) async throws -> Void
    ) {
      self.expectedOwnerID = expectedOwnerID
      self.extract = extract
    }

    func prepare(deviceIdentifier: String, in workingDirectory: URL) async throws -> URL? {
      // Other boards retain their existing preparation until their native recipe
      // has its own qualification. Never apply this board's inputs to another Mac.
      guard deviceIdentifier == "apple,j700" else { return nil }
      let plan = try FirmwareExtractionPlan.bundled(for: deviceIdentifier)
      try validateDirectory(workingDirectory)
      let namespace = workingDirectory.appendingPathComponent("native-firmware", isDirectory: true)
      try ensureDirectory(namespace)
      let recipe = namespace.appendingPathComponent(plan.recipeSHA256, isDirectory: true)
      try ensureDirectory(recipe)
      let output = recipe.appendingPathComponent("raw", isDirectory: true)
      let cache = recipe.appendingPathComponent("ranges", isDirectory: true)
      try await extract(plan, output, cache)
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
