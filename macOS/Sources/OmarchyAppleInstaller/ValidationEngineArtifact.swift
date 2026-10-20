#if os(macOS)
  import Foundation

  public enum ValidationEngineArtifactError: Error, Equatable, Sendable {
    case unavailable
  }

  /// Locates the pinned reference runtime for developer qualification tools.
  /// The app's inspection and planning paths are native and do not use this
  /// locator or require the reference archive to be bundled. Installation
  /// execution currently stages its independently authenticated catalog engine.
  public struct ValidationEngineArtifactLocator: Sendable {
    public static let version = "v0.9.2-aurora.9"
    public static let fileName = "installer-v0.9.2-aurora.9.tar.gz"
    public static let expectedDigest =
      "sha256:86353904d101ef32f3cc607584a38442a948d2111c4514df32778d0afe456b47"
    public static let expectedSizeBytes: UInt64 = 17_893_732

    public init() {}

    public func locate() throws -> PinnedAsahiEngineArchive {
      try locate(
        environment: ProcessInfo.processInfo.environment,
        currentDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath,
          isDirectory: true
        ),
        resourceDirectory: Bundle.main.resourceURL
      )
    }

    public func locate(in bundle: Bundle) throws -> PinnedAsahiEngineArchive {
      try locate(
        environment: [:], currentDirectory: bundle.bundleURL,
        resourceDirectory: bundle.resourceURL)
    }

    func locate(
      environment: [String: String],
      currentDirectory: URL,
      resourceDirectory: URL?
    ) throws -> PinnedAsahiEngineArchive {
      var candidates = [URL]()
      if let override = environment["OMARCHY_VALIDATION_ENGINE_ARCHIVE"],
        !override.isEmpty
      {
        candidates.append(URL(fileURLWithPath: override))
      }
      if let resourceDirectory {
        candidates.append(
          resourceDirectory
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(Self.fileName)
        )
      }
      candidates.append(
        currentDirectory
          .appendingPathComponent("Engine", isDirectory: true)
          .appendingPathComponent("artifacts", isDirectory: true)
          .appendingPathComponent(Self.fileName)
      )
      candidates.append(
        currentDirectory
          .appendingPathComponent("apps", isDirectory: true)
          .appendingPathComponent("omarchy-apple-installer", isDirectory: true)
          .appendingPathComponent("Engine", isDirectory: true)
          .appendingPathComponent("artifacts", isDirectory: true)
          .appendingPathComponent(Self.fileName)
      )

      guard
        let fileURL = candidates.first(where: {
          FileManager.default.fileExists(atPath: $0.path)
        })
      else {
        throw ValidationEngineArtifactError.unavailable
      }
      return try PinnedAsahiEngineArchive(
        fileURL: fileURL,
        expectedDigest: Self.expectedDigest,
        expectedSizeBytes: Self.expectedSizeBytes
      )
    }
  }
#endif
