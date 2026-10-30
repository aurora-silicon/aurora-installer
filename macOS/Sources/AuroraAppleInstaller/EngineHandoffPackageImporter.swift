#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation

  public enum ImportedInstallationIntent: Equatable, Sendable {
    case fresh
    case replace
    case reinstall
    case repair

    static let reinstallOperation = "reinstall-preserving-stage1"
  }

  public struct ImportedEngineHandoffPackage: Sendable {
    public let packageURL: URL
    public let manifestURL: URL
    public let requestURL: URL
    public let identityURL: URL
    public let metadataURL: URL
    public let payloadURL: URL
    public let restoreImageURL: URL?
    public let recoveryTemplateURL: URL?
    public let bindingDigest: String
    public let planDigest: String
    public let deviceIdentifier: String
    public let storeIdentifier: String
    public let installationIntent: ImportedInstallationIntent
    /// The plan's bound experimental hardware record, decoded. Nil on every
    /// supported Mac. The helper still re-runs the decision before using it
    /// (`NativeExperimentalAdmission.verify`).
    public var experimentalAdmission: ExperimentalAdmissionRecord? = nil

    public init(
      packageURL: URL,
      manifestURL: URL,
      requestURL: URL,
      identityURL: URL,
      metadataURL: URL,
      payloadURL: URL,
      restoreImageURL: URL? = nil,
      recoveryTemplateURL: URL? = nil,
      bindingDigest: String,
      planDigest: String,
      deviceIdentifier: String,
      storeIdentifier: String,
      installationIntent: ImportedInstallationIntent = .fresh,
      experimentalAdmission: ExperimentalAdmissionRecord? = nil
    ) {
      self.packageURL = packageURL
      self.manifestURL = manifestURL
      self.requestURL = requestURL
      self.identityURL = identityURL
      self.metadataURL = metadataURL
      self.payloadURL = payloadURL
      self.restoreImageURL = restoreImageURL
      self.recoveryTemplateURL = recoveryTemplateURL
      self.bindingDigest = bindingDigest
      self.planDigest = planDigest
      self.deviceIdentifier = deviceIdentifier
      self.storeIdentifier = storeIdentifier
      self.installationIntent = installationIntent
      self.experimentalAdmission = experimentalAdmission
    }
  }

  public enum EngineHandoffImportError: Error, Equatable, Sendable {
    case unsafeSourceDirectory
    case unsafeDestinationDirectory
    case invalidManifest
    case invalidRequest
    case invalidIdentity
    case bindingMismatch
    case unsafeFile(String)
    case sizeMismatch(String)
    case digestMismatch(String)
    /// A new package that names an engine archive or the retired repair
    /// operation. Only the built-in native engine runs.
    case nativeEngineRequired
  }

  public struct EngineHandoffPackageImporter: Sendable {
    static let importedPrefix = "imported-handoff-"
    private static let maximumControlFileBytes = 65_536

    private let readArtifactChunk: @Sendable (String, FileHandle, Int) throws -> Data?
    public init() { readArtifactChunk = { _, handle, limit in try handle.read(upToCount: limit) } }
    init(readArtifactChunk: @escaping @Sendable (String, FileHandle, Int) throws -> Data?) {
      self.readArtifactChunk = readArtifactChunk
    }

    /// Reuse the importer's exact control schemas and digest binding when the
    /// native disk stage reconstructs execution authority from retained inputs.
    func executionPlan(
      _ package: ImportedEngineHandoffPackage, owner: uid_t = 0
    ) throws -> ValidatedEnginePlan {
      try boundPlan(
        package, owner: owner, intent: .fresh, operation: "install",
        candidateKinds: ["free", "resize"])
    }

    func preservedExecutionPlan(
      _ package: ImportedEngineHandoffPackage, owner: uid_t = 0
    ) throws -> ValidatedEnginePlan {
      try boundPlan(
        package, owner: owner, intent: .reinstall,
        operation: ImportedInstallationIntent.reinstallOperation,
        candidateKinds: ["reinstall"])
    }

    private func boundPlan(
      _ package: ImportedEngineHandoffPackage, owner: uid_t,
      intent: ImportedInstallationIntent, operation: String, candidateKinds: Set<String>
    ) throws -> ValidatedEnginePlan {
      let tree = try NativeHandoffFileTree(package.packageURL, protected: true, owner: owner)
      let manifest = try decodeManifest(
        tree.read("manifest.json", maximum: Self.maximumControlFileBytes))
      let request = try decodeRequest(
        tree.read("request.json", maximum: Self.maximumControlFileBytes))
      let identity = try decodeIdentity(
        tree.read("identity.json", maximum: Self.maximumControlFileBytes))
      try validateBindings(manifest: manifest, request: request, identity: identity)
      guard package.installationIntent == intent, request.operation == operation,
        package.manifestURL == package.packageURL.appendingPathComponent("manifest.json"),
        package.requestURL == package.packageURL.appendingPathComponent("request.json"),
        package.identityURL == package.packageURL.appendingPathComponent("identity.json"),
        candidateKinds.contains(request.candidateKind),
        package.planDigest == request.planDigest, package.bindingDigest == identity.bindingDigest,
        package.deviceIdentifier == request.deviceIdentifier,
        package.storeIdentifier == request.storeIdentifier,
        package.metadataURL
          == package.packageURL.appendingPathComponent(manifest.metadata.fileName),
        package.payloadURL == package.packageURL.appendingPathComponent(manifest.payload.fileName),
        package.restoreImageURL
          == package.packageURL.appendingPathComponent(manifest.restoreImage.fileName),
        identity.repairManifestDigest == nil,
        package.experimentalAdmission?.canonical == request.experimentalAdmission
      else { throw EngineHandoffImportError.bindingMismatch }
      if intent == .reinstall {
        guard package.recoveryTemplateURL == nil,
          manifest.repairManifest == nil, manifest.recoveryTemplate == nil
        else { throw EngineHandoffImportError.bindingMismatch }
      }
      return ValidatedEnginePlan(
        planDigest: request.planDigest, deviceIdentifier: request.deviceIdentifier,
        storeIdentifier: request.storeIdentifier, layoutDigest: request.layoutDigest,
        candidateKind: request.candidateKind, sourceIdentifier: request.sourceIdentifier,
        offsetBytes: request.offsetBytes, lengthBytes: request.lengthBytes,
        engineVersion: request.engineVersion, engineDigest: identity.engineDigest,
        metadataDigest: identity.metadataDigest, payloadDigest: identity.payloadDigest,
        repairManifestDigest: nil, requiredHumanSteps: request.requiredHumanSteps,
        experimentalAdmission: request.experimentalAdmission)
    }

    public func prepare(
      from packageDirectory: FileHandle,
      in destinationDirectory: URL
    ) throws -> ImportedEngineHandoffPackage {
      let sourceDescriptor = packageDirectory.fileDescriptor
      try validateSourceDirectory(sourceDescriptor)
      try validateDestinationDirectory(destinationDirectory)

      let manifestData = try readControlFile(
        "manifest.json",
        from: sourceDescriptor
      )
      let requestData = try readControlFile(
        "request.json",
        from: sourceDescriptor
      )
      let identityData = try readControlFile(
        "identity.json",
        from: sourceDescriptor
      )
      let manifest = try decodeManifest(manifestData)
      let request = try decodeRequest(requestData)
      let identity = try decodeIdentity(identityData)
      try validateBindings(
        manifest: manifest,
        request: request,
        identity: identity
      )
      // Older packages carried an engine archive or a repair manifest for the
      // retired engine. A new submission must name only native execution.
      guard manifest.format == 2, manifest.engine == nil, manifest.repairManifest == nil,
        identity.repairManifestDigest == nil, intent(for: request) != .repair
      else {
        throw EngineHandoffImportError.nativeEngineRequired
      }

      let identifier = UUID().uuidString.lowercased()
      let package = destinationDirectory.appendingPathComponent(
        Self.importedPrefix + identifier,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      var keepPackage = false
      defer {
        if !keepPackage {
          try? FileManager.default.removeItem(at: package)
        }
      }

      let manifestURL = package.appendingPathComponent("manifest.json")
      let requestURL = package.appendingPathComponent("request.json")
      let identityURL = package.appendingPathComponent("identity.json")
      try writePrivate(manifestData, to: manifestURL)
      try writePrivate(requestData, to: requestURL)
      try writePrivate(identityData, to: identityURL)

      let metadataURL = package.appendingPathComponent(
        manifest.metadata.fileName
      )
      let payloadURL = package.appendingPathComponent(manifest.payload.fileName)
      try copyArtifact(
        manifest.metadata,
        role: "metadata",
        from: sourceDescriptor,
        to: metadataURL
      )
      try copyArtifact(
        manifest.payload,
        role: "payload",
        from: sourceDescriptor,
        to: payloadURL
      )

      let restoreImageURL = package.appendingPathComponent(manifest.restoreImage.fileName)
      try copyArtifact(
        manifest.restoreImage, role: "restore-image", from: sourceDescriptor, to: restoreImageURL)
      guard chmod(restoreImageURL.path, S_IRUSR | S_IXUSR) == 0 else {
        throw EngineHandoffImportError.unsafeFile("restore-image")
      }

      let recoveryTemplateURL = manifest.recoveryTemplate.map {
        package.appendingPathComponent($0.fileName)
      }
      if let artifact = manifest.recoveryTemplate, let recoveryTemplateURL {
        try copyArtifact(
          artifact, role: "recovery-template", from: sourceDescriptor, to: recoveryTemplateURL)
      }
      keepPackage = true
      return ImportedEngineHandoffPackage(
        packageURL: package,
        manifestURL: manifestURL,
        requestURL: requestURL,
        identityURL: identityURL,
        metadataURL: metadataURL,
        payloadURL: payloadURL,
        restoreImageURL: restoreImageURL,
        recoveryTemplateURL: recoveryTemplateURL,
        bindingDigest: identity.bindingDigest,
        planDigest: request.planDigest,
        deviceIdentifier: request.deviceIdentifier,
        storeIdentifier: request.storeIdentifier,
        installationIntent: intent(for: request),
        experimentalAdmission: try request.experimentalAdmission.map(
          ExperimentalAdmissionRecord.decode)
      )
    }

    /// Revalidates the original helper-owned snapshot in place. Recovery retry
    /// cannot supply another package, and never duplicates its payload. A
    /// snapshot an older helper retained with an engine archive is still
    /// verified file by file, so its job can continue natively; the archive
    /// itself is never run.
    func reopenRetained(named name: String, in directory: URL) throws
      -> ImportedEngineHandoffPackage
    {
      let prefix = Self.importedPrefix
      guard name.hasPrefix(prefix),
        let identifier = UUID(uuidString: String(name.dropFirst(prefix.count))),
        name == prefix + identifier.uuidString.lowercased()
      else { throw EngineHandoffImportError.invalidManifest }
      try validateDestinationDirectory(directory)
      var parentStatus = stat()
      guard lstat(directory.path, &parentStatus) == 0, parentStatus.st_uid == geteuid() else {
        throw EngineHandoffImportError.unsafeDestinationDirectory
      }
      let package = directory.appendingPathComponent(name, isDirectory: true)
      let descriptor = Darwin.open(package.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw EngineHandoffImportError.unsafeSourceDirectory }
      defer { Darwin.close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
        status.st_mode & 0o077 == 0, status.st_uid == geteuid()
      else { throw EngineHandoffImportError.unsafeSourceDirectory }

      let manifest = try decodeManifest(
        readRetainedFile("manifest.json", from: descriptor, control: true))
      let request = try decodeRequest(
        readRetainedFile("request.json", from: descriptor, control: true))
      let identity = try decodeIdentity(
        readRetainedFile("identity.json", from: descriptor, control: true))
      try validateBindings(manifest: manifest, request: request, identity: identity)
      let artifacts = manifest.artifacts
      let expectedNames = Set(
        ["manifest.json", "request.json", "identity.json"] + artifacts.map(\.fileName))
      guard Set(try FileManager.default.contentsOfDirectory(atPath: package.path)) == expectedNames
      else {
        throw EngineHandoffImportError.invalidManifest
      }
      for artifact in artifacts {
        _ = try readRetainedFile(
          artifact.fileName, from: descriptor, control: false,
          expectedBytes: artifact.sizeBytes, expectedDigest: artifact.digest,
          executable: artifact.fileName == RestoreImageHelper.fileName)
      }
      return ImportedEngineHandoffPackage(
        packageURL: package, manifestURL: package.appendingPathComponent("manifest.json"),
        requestURL: package.appendingPathComponent("request.json"),
        identityURL: package.appendingPathComponent("identity.json"),
        metadataURL: package.appendingPathComponent(manifest.metadata.fileName),
        payloadURL: package.appendingPathComponent(manifest.payload.fileName),
        restoreImageURL: package.appendingPathComponent(manifest.restoreImage.fileName),
        recoveryTemplateURL: manifest.recoveryTemplate.map {
          package.appendingPathComponent($0.fileName)
        },
        bindingDigest: identity.bindingDigest, planDigest: request.planDigest,
        deviceIdentifier: request.deviceIdentifier, storeIdentifier: request.storeIdentifier,
        installationIntent: intent(for: request),
        experimentalAdmission: try request.experimentalAdmission.map(
          ExperimentalAdmissionRecord.decode))
    }

    private func readRetainedFile(
      _ name: String, from directory: Int32, control: Bool,
      expectedBytes: UInt64? = nil, expectedDigest: String? = nil, executable: Bool = false
    ) throws -> Data {
      let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw EngineHandoffImportError.unsafeFile(name) }
      defer { Darwin.close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_mode & 0o077 == 0, status.st_uid == geteuid(), status.st_nlink == 1,
        status.st_size > 0, !control || status.st_size <= Self.maximumControlFileBytes
      else { throw EngineHandoffImportError.unsafeFile(name) }
      if let expectedBytes, UInt64(status.st_size) != expectedBytes {
        throw EngineHandoffImportError.sizeMismatch(name)
      }
      guard !executable || status.st_mode & S_IXUSR != 0 else {
        throw EngineHandoffImportError.unsafeFile(name)
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      var bytes = Data()
      var hasher = SHA256()
      var count: UInt64 = 0
      while let chunk = try handle.read(
        upToCount: control ? Self.maximumControlFileBytes + 1 : 4 * 1_048_576),
        !chunk.isEmpty
      {
        count += UInt64(chunk.count)
        guard count <= UInt64(status.st_size) else {
          throw EngineHandoffImportError.sizeMismatch(name)
        }
        hasher.update(data: chunk)
        if control { bytes.append(chunk) }
      }
      guard count == UInt64(status.st_size) else {
        throw EngineHandoffImportError.sizeMismatch(name)
      }
      if let expectedDigest, SHA256Digest.prefixedHex(hasher.finalize()) != expectedDigest {
        throw EngineHandoffImportError.digestMismatch(name)
      }
      return bytes
    }

    private func validateSourceDirectory(_ descriptor: Int32) throws {
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        throw EngineHandoffImportError.unsafeSourceDirectory
      }
    }

    private func validateDestinationDirectory(_ directory: URL) throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        throw EngineHandoffImportError.unsafeDestinationDirectory
      }
    }

    private func readControlFile(
      _ name: String,
      from directoryDescriptor: Int32
    ) throws -> Data {
      let descriptor = openat(
        directoryDescriptor,
        name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard descriptor >= 0 else {
        throw EngineHandoffImportError.unsafeFile(name)
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumControlFileBytes
      else {
        throw EngineHandoffImportError.unsafeFile(name)
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size)
      else {
        throw EngineHandoffImportError.unsafeFile(name)
      }
      return data
    }

    private func copyArtifact(
      _ artifact: ImportedArtifactRecord,
      role: String,
      from directoryDescriptor: Int32,
      to destination: URL
    ) throws {
      let source = openat(
        directoryDescriptor,
        artifact.fileName,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard source >= 0 else {
        throw EngineHandoffImportError.unsafeFile(role)
      }
      defer { Darwin.close(source) }

      var status = stat()
      guard fstat(source, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        status.st_size > 0
      else {
        throw EngineHandoffImportError.unsafeFile(role)
      }
      guard UInt64(status.st_size) == artifact.sizeBytes else {
        throw EngineHandoffImportError.sizeMismatch(role)
      }

      // On APFS a clone shares the app's verified blocks instead of copying
      // several gigabytes for every attempt. The clone is the helper's own
      // file from here on, so reading it once checks exactly what is kept.
      if fclonefileat(
        source, AT_FDCWD, destination.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0
      {
        do {
          try verifyClone(artifact, role: role, at: destination)
        } catch {
          unlink(destination.path)
          throw error
        }
        return
      }

      let target = Darwin.open(
        destination.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR
      )
      guard target >= 0 else {
        throw EngineHandoffImportError.unsafeFile(role)
      }
      var targetOpen = true
      defer {
        if targetOpen {
          Darwin.close(target)
        }
      }

      let sourceHandle = FileHandle(
        fileDescriptor: source,
        closeOnDealloc: false
      )
      let targetHandle = FileHandle(
        fileDescriptor: target,
        closeOnDealloc: false
      )
      var hasher = SHA256()
      var size: UInt64 = 0
      while let chunk = try readArtifactChunk(role, sourceHandle, 1_048_576),
        !chunk.isEmpty
      {
        let (updatedSize, overflow) = size.addingReportingOverflow(
          UInt64(chunk.count)
        )
        guard !overflow, updatedSize <= artifact.sizeBytes else {
          throw EngineHandoffImportError.sizeMismatch(role)
        }
        try targetHandle.write(contentsOf: chunk)
        hasher.update(data: chunk)
        size = updatedSize
      }
      try targetHandle.synchronize()
      try targetHandle.close()
      targetOpen = false

      guard size == artifact.sizeBytes else {
        throw EngineHandoffImportError.sizeMismatch(role)
      }
      let digest = SHA256Digest.prefixedHex(hasher.finalize())
      guard digest == artifact.digest else {
        throw EngineHandoffImportError.digestMismatch(role)
      }
    }

    private func verifyClone(_ artifact: ImportedArtifactRecord, role: String, at url: URL)
      throws
    {
      let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw EngineHandoffImportError.unsafeFile(role) }
      defer { Darwin.close(descriptor) }
      var status = stat()
      // A clone keeps the source's mode and flags; the import's own are set
      // before anything is read.
      guard fchflags(descriptor, 0) == 0, fchmod(descriptor, S_IRUSR) == 0,
        fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == geteuid(), status.st_nlink == 1,
        UInt64(status.st_size) == artifact.sizeBytes
      else { throw EngineHandoffImportError.unsafeFile(role) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      var hasher = SHA256()
      var size: UInt64 = 0
      while let chunk = try readArtifactChunk(role, handle, 4 * 1_048_576), !chunk.isEmpty {
        size += UInt64(chunk.count)
        guard size <= artifact.sizeBytes else { throw EngineHandoffImportError.sizeMismatch(role) }
        hasher.update(data: chunk)
      }
      guard size == artifact.sizeBytes else { throw EngineHandoffImportError.sizeMismatch(role) }
      guard SHA256Digest.prefixedHex(hasher.finalize()) == artifact.digest else {
        throw EngineHandoffImportError.digestMismatch(role)
      }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
      try data.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o400],
        ofItemAtPath: url.path
      )
    }

    private func decodeManifest(_ data: Data) throws -> ImportedManifest {
      do {
        guard
          let rawObject = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
          throw EngineHandoffImportError.invalidManifest
        }
        var manifestKeys: Set<String> = [
          "format", "binding_digest", "request_file", "identity_file",
          "metadata", "payload", "restore_image",
        ]
        if rawObject["format"] as? Int == 1 { manifestKeys.insert("engine") }
        if rawObject["recovery_template"] != nil { manifestKeys.insert("recovery_template") }
        if rawObject["repair_manifest"] != nil {
          manifestKeys.insert("repair_manifest")
        }
        let object = try exactObject(
          data,
          keys: manifestKeys,
          error: .invalidManifest
        )
        for key in [
          "engine", "metadata", "payload", "restore_image", "repair_manifest", "recovery_template",
        ]
        where object[key] != nil {
          guard let artifact = object[key] as? [String: Any],
            Set(artifact.keys) == ["file_name", "digest", "size_bytes"]
          else {
            throw EngineHandoffImportError.invalidManifest
          }
        }
        let manifest = try JSONDecoder().decode(
          ImportedManifest.self,
          from: data
        )
        let fileNames = manifest.artifacts.map(\.fileName)
        guard [1, 2].contains(manifest.format),
          (manifest.format == 1) == (manifest.engine != nil),
          manifest.requestFile == "request.json",
          manifest.identityFile == "identity.json",
          Set(fileNames).count == fileNames.count,
          Set(fileNames).isDisjoint(
            with: ["manifest.json", "request.json", "identity.json"]
          ),
          manifest.artifacts.allSatisfy(validArtifact),
          manifest.restoreImage.fileName == RestoreImageHelper.fileName,
          manifest.restoreImage.sizeBytes <= RestoreImageHelper.maximumBytes,
          manifest.recoveryTemplate == nil
            || (manifest.recoveryTemplate?.fileName == NativeRecoveryTemplate.archiveFileName
              && manifest.recoveryTemplate!.sizeBytes <= NativeRecoveryTemplate.maximumArchiveBytes)
        else {
          throw EngineHandoffImportError.invalidManifest
        }
        return manifest
      } catch let error as EngineHandoffImportError {
        throw error
      } catch {
        throw EngineHandoffImportError.invalidManifest
      }
    }

    private func decodeRequest(_ data: Data) throws -> ImportedRequest {
      do {
        var keys: Set<String> = [
          "format", "operation", "plan_digest", "device_identifier",
          "store_identifier", "layout_digest", "candidate_kind",
          "source_identifier", "offset_bytes", "length_bytes",
          "engine_version", "required_human_steps",
        ]
        // Only an experimental plan carries the bound record.
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[
          "experimental_admission"] != nil
        {
          keys.insert("experimental_admission")
        }
        _ = try exactObject(data, keys: keys, error: .invalidRequest)
        let request = try JSONDecoder().decode(ImportedRequest.self, from: data)
        guard request.format == 1,
          (request.operation == "install"
            && ["free", "resize", "replace"].contains(request.candidateKind))
            || (request.operation == ImportedInstallationIntent.reinstallOperation
              && request.candidateKind == "reinstall"
              && request.requiredHumanSteps == ["authenticateMachineOwner"])
            || (request.operation == "repair-installed-system"
              && request.candidateKind == "repair"),
          isHexDigest(request.planDigest),
          request.deviceIdentifier.range(
            of: #"^apple,[a-z0-9]+$"#,
            options: .regularExpression
          ) != nil,
          request.storeIdentifier.range(
            of: #"^disk[0-9]+$"#,
            options: .regularExpression
          ) != nil,
          isSHA256Digest(request.layoutDigest),
          request.sourceIdentifier.range(
            of: #"^disk[0-9]+(?:s[0-9]+)?$"#,
            options: .regularExpression
          ) != nil,
          request.lengthBytes > 0,
          !request.engineVersion.isEmpty,
          request.engineVersion.utf8.count <= 128,
          !request.offsetBytes.addingReportingOverflow(
            request.lengthBytes
          ).overflow,
          !request.requiredHumanSteps.isEmpty,
          request.requiredHumanSteps.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 128
          }),
          request.experimentalAdmission.map({
            (try? ExperimentalAdmissionRecord.decode($0))?.deviceIdentifier
              == request.deviceIdentifier && request.operation == "install"
          }) ?? true
        else {
          throw EngineHandoffImportError.invalidRequest
        }
        return request
      } catch let error as EngineHandoffImportError {
        throw error
      } catch {
        throw EngineHandoffImportError.invalidRequest
      }
    }

    private func decodeIdentity(_ data: Data) throws -> ImportedIdentity {
      do {
        guard
          let rawObject = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
          throw EngineHandoffImportError.invalidIdentity
        }
        var identityKeys: Set<String> = [
          "format", "binding_digest", "trust_root_fingerprint",
          "catalog_sequence", "catalog_payload_digest", "plan_digest",
          "engine_digest", "metadata_digest", "payload_digest",
        ]
        if rawObject["repair_manifest_digest"] != nil {
          identityKeys.insert("repair_manifest_digest")
        }
        _ = try exactObject(
          data,
          keys: identityKeys,
          error: .invalidIdentity
        )
        let identity = try JSONDecoder().decode(
          ImportedIdentity.self,
          from: data
        )
        guard identity.format == 1,
          isSHA256Digest(identity.bindingDigest),
          isSHA256Digest(identity.trustRootFingerprint),
          identity.catalogSequence > 0,
          isSHA256Digest(identity.catalogPayloadDigest),
          isHexDigest(identity.planDigest),
          isSHA256Digest(identity.engineDigest),
          isSHA256Digest(identity.metadataDigest),
          isSHA256Digest(identity.payloadDigest)
            && (identity.repairManifestDigest == nil
              || isSHA256Digest(identity.repairManifestDigest!))
        else {
          throw EngineHandoffImportError.invalidIdentity
        }
        return identity
      } catch let error as EngineHandoffImportError {
        throw error
      } catch {
        throw EngineHandoffImportError.invalidIdentity
      }
    }

    private func validateBindings(
      manifest: ImportedManifest,
      request: ImportedRequest,
      identity: ImportedIdentity
    ) throws {
      var planFields = [
        request.deviceIdentifier,
        request.storeIdentifier,
        request.layoutDigest,
        request.candidateKind,
        request.sourceIdentifier,
        String(request.offsetBytes),
        String(request.lengthBytes),
        request.engineVersion,
        identity.engineDigest,
        identity.metadataDigest,
        identity.payloadDigest,
      ]
      if let repairManifestDigest = identity.repairManifestDigest {
        planFields.append(repairManifestDigest)
      }
      planFields.append(request.requiredHumanSteps.joined(separator: ","))
      if let experimental = request.experimentalAdmission { planFields.append(experimental) }
      let engineBound =
        manifest.format == 1
        ? manifest.engine?.digest == identity.engineDigest
        : manifest.format == 2 && manifest.engine == nil
          && identity.engineDigest == NativeExecutionIdentity.digest
          && request.engineVersion == NativeExecutionIdentity.version
      guard manifest.bindingDigest == identity.bindingDigest,
        request.planDigest == identity.planDigest,
        request.planDigest == lengthPrefixedDigest(planFields),
        engineBound,
        manifest.metadata.digest == identity.metadataDigest,
        manifest.payload.digest == identity.payloadDigest,
        manifest.repairManifest?.digest == identity.repairManifestDigest,
        (request.operation == "repair-installed-system"
          && identity.repairManifestDigest != nil)
          || (["install", ImportedInstallationIntent.reinstallOperation].contains(
            request.operation)
            && identity.repairManifestDigest == nil)
      else {
        throw EngineHandoffImportError.bindingMismatch
      }
    }

    private func intent(for request: ImportedRequest) -> ImportedInstallationIntent {
      if request.operation == "repair-installed-system" { return .repair }
      if request.operation == ImportedInstallationIntent.reinstallOperation { return .reinstall }
      if request.candidateKind == "replace" { return .replace }
      return .fresh
    }

    private func exactObject(
      _ data: Data,
      keys: Set<String>,
      error: EngineHandoffImportError
    ) throws -> [String: Any] {
      guard
        let object = try JSONSerialization.jsonObject(with: data)
          as? [String: Any],
        Set(object.keys) == keys
      else {
        throw error
      }
      return object
    }

    private func validArtifact(_ artifact: ImportedArtifactRecord) -> Bool {
      isSafeFileName(artifact.fileName)
        && isSHA256Digest(artifact.digest)
        && artifact.sizeBytes > 0
    }

    private func isSafeFileName(_ value: String) -> Bool {
      !value.isEmpty
        && value != "."
        && value != ".."
        && value.utf8.count <= 255
        && !value.utf8.contains(0)
        && !value.contains("/")
        && !value.contains("\\")
        && (value as NSString).lastPathComponent == value
    }

    private func isSHA256Digest(_ value: String) -> Bool {
      SHA256Digest(rawValue: value) != nil
    }

    private func isHexDigest(_ value: String) -> Bool {
      SHA256Digest(hexadecimal: value) != nil
    }

    private func lengthPrefixedDigest(_ fields: [String]) -> String {
      InstallerDigest.lengthPrefixedSHA256(fields).hexadecimal
    }
  }

  private struct ImportedManifest: Decodable {
    let format: Int
    let bindingDigest: String
    let requestFile: String
    let identityFile: String
    let engine: ImportedArtifactRecord?
    let metadata: ImportedArtifactRecord
    let payload: ImportedArtifactRecord
    let restoreImage: ImportedArtifactRecord
    let repairManifest: ImportedArtifactRecord?
    let recoveryTemplate: ImportedArtifactRecord?

    var artifacts: [ImportedArtifactRecord] {
      [metadata, payload, restoreImage]
        + (engine.map { [$0] } ?? [])
        + (repairManifest.map { [$0] } ?? [])
        + (recoveryTemplate.map { [$0] } ?? [])
    }

    enum CodingKeys: String, CodingKey {
      case format
      case bindingDigest = "binding_digest"
      case requestFile = "request_file"
      case identityFile = "identity_file"
      case engine
      case metadata
      case payload
      case restoreImage = "restore_image"
      case repairManifest = "repair_manifest"
      case recoveryTemplate = "recovery_template"
    }
  }

  private struct ImportedArtifactRecord: Decodable {
    let fileName: String
    let digest: String
    let sizeBytes: UInt64

    enum CodingKeys: String, CodingKey {
      case fileName = "file_name"
      case digest
      case sizeBytes = "size_bytes"
    }
  }

  private struct ImportedRequest: Decodable {
    let format: Int
    let operation: String
    let planDigest: String
    let deviceIdentifier: String
    let storeIdentifier: String
    let layoutDigest: String
    let candidateKind: String
    let sourceIdentifier: String
    let offsetBytes: UInt64
    let lengthBytes: UInt64
    let engineVersion: String
    let requiredHumanSteps: [String]
    let experimentalAdmission: String?

    enum CodingKeys: String, CodingKey {
      case format
      case operation
      case planDigest = "plan_digest"
      case deviceIdentifier = "device_identifier"
      case storeIdentifier = "store_identifier"
      case layoutDigest = "layout_digest"
      case candidateKind = "candidate_kind"
      case sourceIdentifier = "source_identifier"
      case offsetBytes = "offset_bytes"
      case lengthBytes = "length_bytes"
      case engineVersion = "engine_version"
      case requiredHumanSteps = "required_human_steps"
      case experimentalAdmission = "experimental_admission"
    }
  }

  private struct ImportedIdentity: Decodable {
    let format: Int
    let bindingDigest: String
    let trustRootFingerprint: String
    let catalogSequence: UInt64
    let catalogPayloadDigest: String
    let planDigest: String
    let engineDigest: String
    let metadataDigest: String
    let payloadDigest: String
    let repairManifestDigest: String?

    enum CodingKeys: String, CodingKey {
      case format
      case bindingDigest = "binding_digest"
      case trustRootFingerprint = "trust_root_fingerprint"
      case catalogSequence = "catalog_sequence"
      case catalogPayloadDigest = "catalog_payload_digest"
      case planDigest = "plan_digest"
      case engineDigest = "engine_digest"
      case metadataDigest = "metadata_digest"
      case payloadDigest = "payload_digest"
      case repairManifestDigest = "repair_manifest_digest"
    }
  }
#endif
