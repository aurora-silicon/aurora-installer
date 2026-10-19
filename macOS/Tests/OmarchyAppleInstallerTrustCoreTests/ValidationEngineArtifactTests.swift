#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class ValidationEngineArtifactTests: XCTestCase {
    func testInspectionIdentityIsPinnedToTheReproducedRuntime() {
      XCTAssertEqual(
        ValidationEngineArtifactLocator.version,
        "v0.9.2-aurora.4"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.fileName,
        "installer-v0.9.2-aurora.4.tar.gz"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.expectedDigest,
        "sha256:d92ffe7f908613deadcd1fd16c246588880987ab9c2dd62863b3c39f32098663"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.expectedSizeBytes,
        17_887_533
      )
    }

    func testAppBundleLookupUsesThePinnedEngineFilename() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let app = root.appendingPathComponent("Fixture.app")
      let contents = app.appendingPathComponent("Contents")
      let resources = contents.appendingPathComponent("Resources/Engine/artifacts")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "org.aurorasilicon.engine-fixture"],
        format: .xml, options: 0)
      try info.write(to: contents.appendingPathComponent("Info.plist"))
      let bundle = try XCTUnwrap(Bundle(url: app))
      XCTAssertThrowsError(try ValidationEngineArtifactLocator().locate(in: bundle))
      let engine = resources.appendingPathComponent(ValidationEngineArtifactLocator.fileName)
      try Data("fixture".utf8).write(to: engine)
      XCTAssertEqual(
        try ValidationEngineArtifactLocator().locate(in: bundle).fileURL.path, engine.path)
    }

    func testEnvironmentOverrideSelectsExactValidationArtifactIdentity()
      throws
    {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("engine.tar.gz")
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: archive.path,
          contents: Data("fixture".utf8)
        ))

      let result = try ValidationEngineArtifactLocator().locate(
        environment: ["OMARCHY_VALIDATION_ENGINE_ARCHIVE": archive.path],
        currentDirectory: root,
        resourceDirectory: nil
      )

      XCTAssertEqual(result.fileURL, archive)
      XCTAssertEqual(
        result.expectedDigest,
        ValidationEngineArtifactLocator.expectedDigest
      )
      XCTAssertEqual(
        result.expectedSizeBytes,
        ValidationEngineArtifactLocator.expectedSizeBytes
      )
    }

    func testMissingValidationArtifactFailsClosed() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(
        try ValidationEngineArtifactLocator().locate(
          environment: [:],
          currentDirectory: root,
          resourceDirectory: nil
        )
      ) {
        XCTAssertEqual(
          $0 as? ValidationEngineArtifactError,
          .unavailable
        )
      }
    }

    private func makeDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-validation-artifact-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return root
    }
  }
#endif
