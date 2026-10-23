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
      let directory = try realDirectory(parent)
        .appendingPathComponent("firmware-image-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = directory.appendingPathComponent("recovery")
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      // The command runner refuses any limit above 90 seconds before starting
      // the process. Without hdiutil's checksum pass an attach takes seconds.
      let command: @Sendable (String, [String]) throws -> Data = {
        try AccountNativeCommand.checked($0, $1, timeout: 90)
      }
      do {
        // The image's SHA-256 was verified against the signed plan when it was
        // staged, so hdiutil's own checksum pass over 1.5 GB is skipped.
        let response = try command(
          "/usr/bin/hdiutil",
          [
            "attach", "-plist", "-readonly", "-nobrowse", "-noverify", "-owners", "on",
            "-mountpoint", root.path, image.path,
          ])
        let device = try attachedDevice(response, root: root)
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

    /// The directory's real path. Foundation's symlink resolution drops the
    /// `/private` prefix of /var and /tmp, but hdiutil and the kernel report
    /// mount points with it, so every comparison below would fail.
    static func realDirectory(_ url: URL) throws -> URL {
      guard let resolved = realpath(url.path, nil) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      defer { free(resolved) }
      return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// The one volume hdiutil mounted, exactly at this attempt's mountpoint.
    static func attachedDevice(_ response: Data, root: URL) throws -> String {
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
      return String(name.dropFirst(5))
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

    /// Regular files by relative path, and the image's symbolic links, each
    /// resolved to the regular file it names in its own directory.
    struct Snapshot: Sendable {
      var files: [String: Data]
      var links: [String: String]
    }

    static func snapshot(
      root: URL, prefix: String, tree: NativeHandoffFileTree, owner: uid_t
    ) throws -> Snapshot {
      let root = root.resolvingSymlinksInPath()
      guard NativeHandoffEvidence.safeRelative(prefix) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let descriptor = try tree.fileDescriptor(prefix)
      defer { close(descriptor) }
      var directory = stat()
      guard fstat(descriptor, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
        directory.st_uid == owner, directory.st_mode & 0o022 == 0
      else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let source = root.appendingPathComponent(prefix)
      var files = [String: Data]()
      var named = [String: String]()
      var total = 0
      for relative in try relativeEntries(root: source, maximum: 20000, allowLinks: true) {
        try Task.checkCancellation()
        let url = source.appendingPathComponent(relative)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeFirmwareInputFailure.invalidSource }
        if info.st_mode & S_IFMT == S_IFDIR { continue }
        if info.st_mode & S_IFMT == S_IFLNK {
          named[relative] = try sibling(of: relative, linkAt: url)
          continue
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
          info.st_size <= 64 << 20, info.st_size <= (256 << 20) - total,
          files.count < 10000
        else { throw NativeFirmwareInputFailure.budget }
        // Empty source files are retained in the fallback inventory.
        let data = try tree.read(prefix + "/" + relative, maximum: 64 << 20)
        total += data.count
        files[relative] = data
      }
      // Follow each link through at most a few other links to a regular file.
      // A link that ends nowhere is left out, like a file the image lacks.
      var links = [String: String]()
      for (alias, first) in named {
        var target = first
        var hops = 1
        while let next = named[target] {
          hops += 1
          guard hops <= 8 else { throw NativeFirmwareInputFailure.invalidSource }
          target = next
        }
        if files[target] != nil { links[alias] = target }
      }
      return Snapshot(files: files, links: links)
    }

    /// A link may only name another entry in its own directory.
    static func sibling(of relative: String, linkAt url: URL) throws -> String {
      var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      let count = readlink(url.path, &buffer, buffer.count - 1)
      guard count > 0 else { throw NativeFirmwareInputFailure.invalidSource }
      let target = String(
        decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard !target.contains("/"), target != ".", target != "..",
        NativeHandoffEvidence.safeRelative(target)
      else { throw NativeFirmwareInputFailure.invalidSource }
      let directory = relative.split(separator: "/").dropLast().joined(separator: "/")
      return directory.isEmpty ? target : directory + "/" + target
    }

    /// Keep enumeration relative to its root. Foundation may spell absolute
    /// temporary URLs differently, and unreadable directories must fail closed.
    static func relativeEntries(
      root: URL, maximum: Int, allowLinks: Bool = false
    ) throws -> [String] {
      var pending = [""]
      var entries = [String]()
      while let parent = pending.popLast() {
        try Task.checkCancellation()
        let names = try FileManager.default.contentsOfDirectory(
          atPath: parent.isEmpty ? root.path : root.appendingPathComponent(parent).path)
        guard names.count <= maximum - entries.count else {
          throw NativeFirmwareInputFailure.budget
        }
        for name in names {
          let relative = parent.isEmpty ? name : parent + "/" + name
          guard NativeHandoffEvidence.safeRelative(relative) else {
            throw NativeFirmwareInputFailure.invalidSource
          }
          var info = stat()
          guard lstat(root.appendingPathComponent(relative).path, &info) == 0,
            [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT)
              || (allowLinks && info.st_mode & S_IFMT == S_IFLNK)
          else { throw NativeFirmwareInputFailure.invalidSource }
          entries.append(relative)
          if info.st_mode & S_IFMT == S_IFDIR { pending.append(relative) }
        }
      }
      return entries
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
