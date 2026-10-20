#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import RecoveryAccountCore

  enum NativeFirmwareInputFailure: Error {
    case invalidSource, budget, detachFailed
    case cleanupFailed(operation: Error, cleanup: Error)
  }

  /// A private, uniquely named attachment. Never adopt or detach a host mount.
  struct NativeFirmwareMountedImage: Sendable {
    let directory: URL
    let root: URL
    let device: String
    let command: @Sendable (String, [String]) throws -> Data

    static func open(image: URL, parent: URL) throws -> Self {
      let directory = parent.appendingPathComponent("firmware-image-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = directory.appendingPathComponent("recovery")
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let command: @Sendable (String, [String]) throws -> Data = {
        try AccountNativeCommand.checked($0, $1, timeout: 180)
      }
      do {
        let response = try command(
          "/usr/bin/hdiutil",
          [
            "attach", "-plist", "-readonly", "-nobrowse", "-owners", "on",
            "-mountpoint", root.path, image.path,
          ])
        guard
          let plist = try PropertyListSerialization.propertyList(
            from: response, format: nil) as? [String: Any],
          let entries = plist["system-entities"] as? [[String: Any]],
          entries.filter({ $0["mount-point"] != nil }).count == 1,
          let mounted = entries.first(where: { $0["mount-point"] as? String == root.path }),
          let name = mounted["dev-entry"] as? String, name.hasPrefix("/dev/disk"),
          String(name.dropFirst(5)).range(
            of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil
        else { throw NativeFirmwareInputFailure.invalidSource }
        let device = String(name.dropFirst(5))
        _ = try NativeHandoffFileTree(
          root, protected: true, volumeRoot: true, volumeDevice: device)
        return Self(directory: directory, root: root, device: device, command: command)
      } catch {
        // An attach may have completed before its response became available.
        // The unique mountpoint is the only attachment this attempt may retire.
        let operation = error
        do {
          var filesystem = statfs()
          guard statfs(root.path, &filesystem) == 0 else {
            throw NativeFirmwareInputFailure.detachFailed
          }
          let mountedAt = withUnsafeBytes(of: filesystem.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
          }
          if mountedAt == root.path { _ = try command("/usr/bin/hdiutil", ["detach", root.path]) }
          try FileManager.default.removeItem(at: directory)
        } catch {
          throw NativeFirmwareInputFailure.cleanupFailed(operation: operation, cleanup: error)
        }
        throw operation
      }
    }

    func close() throws {
      _ = try command("/usr/bin/hdiutil", ["detach", "/dev/" + device])
      // A failed detach preserves both the mount and its ownership directory.
      try FileManager.default.removeItem(at: directory)
    }

    static func withCleanup<T>(_ image: Self, body: () async throws -> T) async throws -> T {
      let result: T
      do { result = try await body() } catch {
        let operation = error
        do { try image.close() } catch {
          throw NativeFirmwareInputFailure.cleanupFailed(operation: operation, cleanup: error)
        }
        throw operation
      }
      try image.close()
      return result
    }
  }

  enum NativeFirmwareInputFiles {
    /// A separate firmware budget keeps the boot and metadata readers bounded.
    static func read(
      _ tree: NativeHandoffFileTree, path: String, maximum: Int, owner: uid_t,
      expected: NativeStubFileIdentity? = nil
    ) throws -> Data {
      guard maximum > 0, maximum <= 256 << 20 else { throw NativeFirmwareInputFailure.budget }
      let descriptor = try tree.fileDescriptor(path)
      defer { close(descriptor) }
      let identity = try NativeStubFileStore.identity(descriptor, owner: owner, maximum: maximum)
      guard identity.bytes > 0, expected == nil || identity == expected else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      var data = Data()
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      while data.count < identity.bytes {
        try Task.checkCancellation()
        let chunk = try handle.read(upToCount: min(4 << 20, identity.bytes - data.count)) ?? Data()
        guard !chunk.isEmpty else { throw NativeFirmwareInputFailure.invalidSource }
        data.append(chunk)
      }
      guard NativeStubFileStore.hash(data) == identity.sha256 else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      return data
    }

    static func snapshot(
      root: URL, prefix: String, tree: NativeHandoffFileTree, owner: uid_t
    ) throws -> [String: Data] {
      guard NativeHandoffEvidence.safeRelative(prefix) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let descriptor = try tree.fileDescriptor(prefix)
      defer { close(descriptor) }
      var directory = stat()
      guard fstat(descriptor, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
        directory.st_uid == owner, directory.st_mode & 0o022 == 0 else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      var failure: Error?
      guard let enumerator = FileManager.default.enumerator(
          at: root.appendingPathComponent(prefix), includingPropertiesForKeys: nil,
          errorHandler: { _, error in failure = error; return false })
      else { throw NativeFirmwareInputFailure.invalidSource }
      var files = [String: Data]()
      var total = 0
      var entries = 0
      let base = root.appendingPathComponent(prefix).path + "/"
      for case let url as URL in enumerator {
        try Task.checkCancellation()
        entries += 1
        guard entries <= 20000, url.path.hasPrefix(base) else {
          throw NativeFirmwareInputFailure.budget
        }
        let relative = String(url.path.dropFirst(base.count))
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeFirmwareInputFailure.invalidSource }
        if info.st_mode & S_IFMT == S_IFDIR { continue }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
          info.st_size <= 64 << 20, info.st_size <= (256 << 20) - total,
          files.count < 10000
        else { throw NativeFirmwareInputFailure.budget }
        // Empty source files are retained in the fallback inventory.
        let data = try tree.read(prefix + "/" + relative, maximum: 64 << 20)
        total += data.count
        files[relative] = data
      }
      if let failure { throw failure }
      return files
    }

    static func write(_ bytes: Data, to url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try bytes.write(to: url, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }
#endif
