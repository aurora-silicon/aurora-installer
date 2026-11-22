import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// RestoreImageDirectory.stream and RestoreImageStubFiles against the images in
// Fixtures/RestoreImageStubFiles (generate.py, member SHA-256s from Python's
// zipfile) and the admitted images of Fixtures/RestoreImageStubPlan: every
// written file holds its member's bytes, links their targets, and a second run
// adopts the first; a changed file, a link or a writable directory in the way,
// and a body that doesn't decode to its declared bytes stop the run with
// nothing published.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }

  static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  static let files = here.appendingPathComponent("Fixtures/RestoreImageStubFiles")
  static let plans = here.appendingPathComponent("Fixtures/RestoreImageStubPlan")
  static let group = "6A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8"

  struct Image {
    let bytes: [UInt8]
    let directory: RestoreImageDirectory
    init(_ url: URL) throws {
      bytes = [UInt8](try Data(contentsOf: url))
      let copy = bytes
      directory = try RestoreImageDirectory.read(archiveSize: copy.count) {
        Data(copy[$0..<($0 + $1)])
      }
    }
    func read(_ offset: Int, _ count: Int) throws -> Data { Data(bytes[offset..<(offset + count)]) }
    func entry(_ name: String) -> RestoreImageDirectory.Entry {
      directory.entries.first { $0.name == name }!
    }
    func plan(_ expected: [String: Any]) throws -> RestoreImageStubPlan {
      let manifest = try directory.contents(entry("BuildManifest.plist"), read: read)
      return try RestoreImageStubPlan(
        directory: directory, read: read, productVersion: expected["version"] as! String,
        deviceClass: expected["device_class"] as! String,
        boardID: UInt64(expected["board"] as! Int), chipID: UInt64(expected["chip"] as! Int),
        pin: .init(
          sourceBytes: bytes.count, manifestSHA256: RecoveryDigest.sha256(manifest),
          build: expected["build"] as! String),
        sha256: RecoveryDigest.sha256)
    }
  }

  /// Fresh System, Preboot and Recovery roots.
  static func roots() throws -> (URL, [String: URL]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stub-files-" + UUID().uuidString)
    var roots = [String: URL]()
    for role in RestoreImageStubFiles.roles {
      let root = base.appendingPathComponent(role)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      chmod(root.path, 0o755)
      roots[role] = root
    }
    chmod(base.path, 0o755)
    return (base, roots)
  }

  static func sha(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map(RecoveryDigest.sha256)
  }

  /// Every name under `url` that is a leftover temporary file.
  static func leftovers(_ url: URL) -> [String] {
    (FileManager.default.subpaths(atPath: url.path) ?? []).filter {
      $0.split(separator: "/").last?.hasPrefix(".aurora-stub-") == true
    }
  }

  static func write(
    _ image: Image, _ plan: RestoreImageStubPlan, _ roots: [String: URL], chunk: Int = 65536,
    group: String = group
  ) -> Result<RestoreImageStubFiles, Error> {
    Result {
      try RestoreImageStubFiles(
        plan: plan, directory: image.directory, read: image.read, roots: roots, group: group,
        chunkBytes: chunk)
    }
  }

  /// The written stub agrees with the plan and the members' bytes, and what
  /// it leaves pending would complete the receipts in the main installer's order.
  static func verify(
    _ name: String, _ image: Image, _ plan: RestoreImageStubPlan,
    _ files: RestoreImageStubFiles, _ roots: [String: URL], sha256: [String: String]
  ) {
    var wanted = [(String, String, String?, String?)]()  // role, path, data name, member
    for copy in plan.copies {
      // A link's receipt has no installer data name, as in the main installer.
      let link = plan.linkTargets[copy.member] != nil
      wanted.append((copy.role, copy.path, link ? nil : copy.installerDataName, copy.member))
    }
    wanted.append(
      ("Preboot", plan.restorePath + "/BuildManifest.plist", "BuildManifest.plist", nil))
    wanted.append(
      ("Recovery", RestoreImageStubFiles.recoveryImagePath, nil, plan.recoveryMember.name))
    wanted.append(("System", RestoreImageStubFiles.systemVersionPath, "SystemVersion.plist", nil))
    // Each pending file goes where `position` (installed receipts before it)
    // says: the merged list is then the main installer's full order.
    var merged = [(RestoreImageStubFiles.Installed?, RestoreImageStubFiles.Pending?)]()
    var installed = files.installed[...]
    var pending = files.pending.sorted(by: { $0.position < $1.position })[...]
    while !installed.isEmpty || !pending.isEmpty {
      if let next = pending.first, next.position == files.installed.count - installed.count {
        merged.append((nil, next))
        pending = pending.dropFirst()
      } else if let next = installed.first {
        merged.append((next, nil))
        installed = installed.dropFirst()
      } else {
        expect(false, "\(name): pending position past the end")
        break
      }
    }
    expect(merged.count == wanted.count, "\(name): \(merged.count) receipts, want \(wanted.count)")
    for ((done, left), want) in zip(merged, wanted) {
      let full = want.0 == "System" ? want.1 : group + "/" + want.1
      if let left {
        expect(
          left.role == want.0 && left.path == want.1 && left.member == want.3
            && left.installerDataName == want.2,
          "\(name): pending \(left.path) in order, want \(want.1)")
        expect(
          !FileManager.default.fileExists(atPath: roots[want.0]!.appendingPathComponent(full).path),
          "\(name): pending \(full) was written")
        continue
      }
      guard let installed = done else { continue }
      expect(
        installed.role == want.0 && installed.path == full && installed.installerDataName == want.2,
        "\(name): \(installed.path) in order, want \(full)")
      let url = roots[want.0]!.appendingPathComponent(full)
      if let member = want.3, let target = plan.linkTargets[member] {
        let on = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        expect(
          on == target && installed.linkTarget == target, "\(name): link \(full) -> \(on ?? "-")")
        expect(
          installed.identity.sha256 == RecoveryDigest.sha256(Data(target.utf8)),
          "\(name): link identity")
        continue
      }
      let digest = sha(url)
      expect(digest == installed.identity.sha256, "\(name): \(full) on disk matches its identity")
      if let member = want.3 {
        expect(digest == sha256[member], "\(name): \(full) holds \(member)'s bytes")
        expect(installed.identity.bytes == image.entry(member).size, "\(name): \(full) size")
      } else if want.1.hasSuffix("BuildManifest.plist") {
        expect(digest == RecoveryDigest.sha256(plan.manifest), "\(name): manifest")
      } else {
        expect(digest == RecoveryDigest.sha256(plan.systemVersion), "\(name): system version")
      }
      var info = stat()
      expect(
        lstat(url.path, &info) == 0 && info.st_mode & 0o7777 == 0o644 && info.st_nlink == 1,
        "\(name): \(full) is 0644 with one name")
    }
    // Every directory the writer made is 0755, whatever the umask.
    for (_, root) in roots {
      for path in FileManager.default.subpaths(atPath: root.path) ?? [] {
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR
        else { continue }
        expect(info.st_mode & 0o7777 == 0o755, "\(name): directory \(path) is not 0755")
      }
    }
  }

  static func pending(_ list: [[String: Any]]) -> [RestoreImageStubFiles.Pending] {
    list.map {
      RestoreImageStubFiles.Pending(
        member: $0["member"] as! String, role: $0["role"] as! String,
        path: $0["path"] as! String, installerDataName: $0["installer_data"] as? String,
        appleEncrypted: $0["aea"] as! Bool, compressed: $0["compressed"] as! Bool,
        position: $0["position"] as! Int)
    }
  }

  static func main() throws {
    // Directories must come out 0755 whatever the umask.
    umask(0o077)
    let planExpected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: plans.appendingPathComponent("expected.json"))) as! [String: Any]
    let expected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: files.appendingPathComponent("expected.json"))) as! [String: Any]
    var written = 0

    // This directory's images and, as "plan/<name>", every plan image that
    // admits a plan; member SHA-256s from Python's zipfile.
    var cases = [(String, URL, [String: String], [RestoreImageStubFiles.Pending])]()
    for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
      guard let value = value as? [String: Any] else { continue }
      let url =
        name.hasPrefix("plan/")
        ? plans.appendingPathComponent(String(name.dropFirst(5)) + ".zip")
        : files.appendingPathComponent(name + ".zip")
      cases.append(
        (
          name, url, value["sha256"] as! [String: String],
          pending(value["pending"] as! [[String: Any]])
        ))
    }
    let admitted = (planExpected["cases"] as! [String: Any]).merging(
      planExpected["recovery_only"] as! [String: Any]
    ) { a, _ in a }.filter { $0.value is [String: Any] }.keys.sorted()
    expect(
      Set(cases.map(\.0).filter { $0.hasPrefix("plan/") }) == Set(admitted.map { "plan/" + $0 }),
      "every admitted plan image is a case")
    expect(cases.count >= 4, "cases: \(cases.count)")

    for (name, url, sums, pendingFiles) in cases {
      let image = try Image(url)
      let plan = try image.plan(planExpected)
      // Streaming in any chunk size gives the member's bytes.
      for entry in image.directory.entries where !entry.isDirectory && !entry.isSymbolicLink {
        for chunk in [1, 4096, 65536, RestoreImageDirectory.streamChunk]
        where chunk > 1 || entry.size <= 4096 {
          var hash = RecoveryDigest.Stream()
          var largest = 0
          do {
            try image.directory.stream(entry, chunkBytes: chunk, read: image.read) {
              largest = max(largest, $0.count)
              hash.update($0)
            }
            expect(hash.finish() == sums[entry.name], "\(name): \(entry.name) streamed at \(chunk)")
            expect(largest <= chunk, "\(name): \(entry.name) chunk \(largest) > \(chunk)")
          } catch {
            expect(false, "\(name): \(entry.name) at \(chunk): \(error)")
          }
        }
      }
      for chunk in [4096, RestoreImageDirectory.streamChunk] {
        let (base, roots) = try roots()
        defer { try? FileManager.default.removeItem(at: base) }
        guard case .success(let files) = write(image, plan, roots, chunk: chunk) else {
          expect(false, "\(name): write at \(chunk): \(write(image, plan, roots))")
          continue
        }
        written += 1
        verify(name, image, plan, files, roots, sha256: sums)
        expect(files.pending == pendingFiles, "\(name): pending \(files.pending)")
        expect(leftovers(base).isEmpty, "\(name): temporary files left: \(leftovers(base))")
        // A second run adopts every file and link.
        if case .success(let again) = write(image, plan, roots, chunk: chunk) {
          expect(
            again.installed == files.installed && again.pending == files.pending,
            "\(name): second run differs")
        } else {
          expect(false, "\(name): second run refused")
        }
      }
    }

    // Faults, on ok.zip.
    let image = try Image(plans.appendingPathComponent("ok.zip"))
    let plan = try image.plan(planExpected)
    let kernel = group + "/Restore/kernelcache.release.mac14j"
    func fault(
      _ what: String, _ want: RestoreImageStubFiles.Failure,
      group: String = group, roles: [String]? = nil, left: Int = 0,
      _ setup: (URL, [String: URL]) throws -> Void = { _, _ in }
    ) throws {
      let (base, all) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      try setup(base, all)
      let roots = roles.map { kept in all.filter { kept.contains($0.key) } } ?? all
      let result = write(image, plan, roots, group: group)
      if case .failure(let error as RestoreImageStubFiles.Failure) = result {
        expect(error == want, "\(what): \(error), want \(want)")
      } else {
        expect(false, "\(what): \(result), want \(want)")
      }
      expect(leftovers(base).count == left, "\(what): temporary files left")
    }
    try fault("group not a UUID", .invalidPlan, group: "Restore")
    try fault("group in lower case", .invalidPlan, group: group.lowercased())
    try fault("no Recovery root", .invalidPlan, roles: ["System", "Preboot"])
    // Only the three stub volumes: another root is not one this pass writes.
    do {
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      var more = roots
      more["Data"] = roots["System"]!
      let result = write(image, plan, more)
      if case .failure(let error as RestoreImageStubFiles.Failure) = result {
        expect(error == .invalidPlan, "a fourth root: \(error)")
      } else {
        expect(false, "a fourth root: \(result)")
      }
    }
    // A destination that holds other bytes stops the run and survives.
    do {
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      let url = roots["Preboot"]!.appendingPathComponent(kernel)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("other".utf8).write(to: url)
      chmod(url.path, 0o644)
      let result = write(image, plan, roots)
      if case .failure(let error as RestoreImageStubFiles.Failure) = result {
        expect(error == .changedFile, "a changed file: \(error)")
      } else {
        expect(false, "a changed file: \(result)")
      }
      expect(sha(url) == RecoveryDigest.sha256(Data("other".utf8)), "a changed file is kept")
      expect(leftovers(base).isEmpty, "a changed file: temporary files left")
    }
    let bootcaches = "usr/standalone/bootcaches.plist"
    let temporary = RestoreImageStubFiles.Tree.temporaryName(namespace: group, path: bootcaches)
    let kernelTemporary = RestoreImageStubFiles.Tree.temporaryName(namespace: group, path: kernel)
    // A run stopped after naming a file and before removing its private name.
    do {
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      _ = try write(image, plan, roots).get()
      let url = roots["Preboot"]!.appendingPathComponent(kernel)
      let stale = url.deletingLastPathComponent().appendingPathComponent(kernelTemporary)
      expect(link(url.path, stale.path) == 0, "hard link the private name")
      let again = write(image, plan, roots)
      var info = stat()
      expect(
        (try? again.get()) != nil && leftovers(base).isEmpty && lstat(url.path, &info) == 0
          && info.st_nlink == 1,
        "an interrupted run runs again: \(again)")
    }
    // A private name that shares a file with something other than its
    // destination is not ours to remove.
    do {
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      let parent = roots["System"]!.appendingPathComponent("usr/standalone")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      chmod(parent.path, 0o755)
      chmod(parent.deletingLastPathComponent().path, 0o755)
      let outside = base.appendingPathComponent("outside")
      try Data("keep".utf8).write(to: outside)
      chmod(outside.path, 0o644)
      expect(link(outside.path, parent.appendingPathComponent(temporary).path) == 0, "link outside")
      // The destination exists, as its own file: only the inode check tells them apart.
      let destination = parent.appendingPathComponent("bootcaches.plist")
      try image.directory.contents(image.entry(bootcaches), read: image.read).write(to: destination)
      chmod(destination.path, 0o644)
      let result = write(image, plan, roots)
      if case .failure(let error as RestoreImageStubFiles.Failure) = result {
        expect(error == .unsafeFile, "a private name shared elsewhere: \(error)")
      } else {
        expect(false, "a private name shared elsewhere: \(result)")
      }
      var info = stat()
      expect(
        lstat(outside.path, &info) == 0 && info.st_nlink == 2, "the shared private name is kept")
    }
    // A destination with a second name elsewhere is not adopted.
    try fault("a destination with two names", .unsafeFile) { base, roots in
      let url = roots["System"]!.appendingPathComponent(bootcaches)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      chmod(url.deletingLastPathComponent().path, 0o755)
      chmod(url.deletingLastPathComponent().deletingLastPathComponent().path, 0o755)
      try image.directory.contents(image.entry(bootcaches), read: image.read).write(to: url)
      chmod(url.path, 0o644)
      _ = link(url.path, base.appendingPathComponent("second").path)
    }
    // Things of another user's in the way (only root can make them).
    if geteuid() == 0 {
      try fault("a directory of another user's", .unsafeFile) { _, roots in
        let url = roots["Preboot"]!.appendingPathComponent(group)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, 0o755)
        chown(url.path, 1234, 1234)
      }
      try fault("an identical file of another user's", .unsafeFile) { _, roots in
        let url = roots["System"]!.appendingPathComponent(bootcaches)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(url.deletingLastPathComponent().path, 0o755)
        chmod(url.deletingLastPathComponent().deletingLastPathComponent().path, 0o755)
        try image.directory.contents(image.entry(bootcaches), read: image.read).write(to: url)
        chmod(url.path, 0o644)
        chown(url.path, 1234, 1234)
      }
      try fault("a link of another user's", .changedFile) { _, roots in
        var path = roots["Preboot"]!
        for part in [group, "Restore", "Bootability", "Frameworks", "Boot.framework", "Versions"] {
          path = path.appendingPathComponent(part)
          try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
          chmod(path.path, 0o755)
        }
        let url = path.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "A")
        lchown(url.path, 1234, 1234)
      }
    }
    try fault("a link for a directory", .unsafeFile) { base, roots in
      let elsewhere = base.appendingPathComponent("elsewhere")
      try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
      chmod(elsewhere.path, 0o755)
      try FileManager.default.createSymbolicLink(
        at: roots["Preboot"]!.appendingPathComponent(group), withDestinationURL: elsewhere)
    }
    try fault("a link for a file", .unsafeFile) { base, roots in
      let url = roots["System"]!.appendingPathComponent("usr/standalone/bootcaches.plist")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: base.appendingPathComponent("target"))
      try FileManager.default.createSymbolicLink(
        at: url, withDestinationURL: base.appendingPathComponent("target"))
    }
    try fault("a link with another target", .changedFile) { _, roots in
      let url = roots["Preboot"]!.appendingPathComponent(
        group + "/Restore/Bootability/Frameworks/Boot.framework/Versions/Current")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "B")
    }
    try fault("a directory others can write", .unsafeFile) { _, roots in
      let url = roots["Preboot"]!.appendingPathComponent(group)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      chmod(url.path, 0o777)
    }
    try fault("a root others can write", .unsafeFile) { _, roots in
      chmod(roots["System"]!.path, 0o775)
    }
    try fault("a file where a directory goes", .unsafeFile) { _, roots in
      try Data().write(to: roots["Preboot"]!.appendingPathComponent(group))
    }
    try fault("a stale temporary link", .unsafeFile, left: 1) { base, roots in
      let parent = roots["System"]!.appendingPathComponent("usr/standalone")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      chmod(parent.path, 0o755)
      chmod(parent.deletingLastPathComponent().path, 0o755)
      try FileManager.default.createSymbolicLink(
        atPath: parent.appendingPathComponent(temporary).path, withDestinationPath: base.path)
    }

    // A stale temporary file of ours is replaced.
    do {
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      let parent = roots["System"]!.appendingPathComponent("usr/standalone")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      chmod(parent.path, 0o755)
      chmod(parent.deletingLastPathComponent().path, 0o755)
      try Data("half".utf8).write(to: parent.appendingPathComponent(temporary))
      expect(
        (try? write(image, plan, roots).get()) != nil && leftovers(base).isEmpty,
        "a stale temporary file is replaced")
    }

    // Bodies that don't decode to their declared bytes: no file of theirs appears.
    let llb = "Firmware/all_flash/LLB.j314s.RELEASE.im4p"
    let trust = "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache"
    for (name, member) in [
      ("deflate-trailing", llb), ("deflate-long", llb), ("deflate-short", llb),
      ("deflate-truncated", llb), ("deflate-short-crc", llb), ("stored-crc", trust),
    ] {
      expect(expected[name] as? String == "refuse", "\(name) is a refusing case")
      let bad = try Image(files.appendingPathComponent(name + ".zip"))
      for chunk in [1, 7, 4096, RestoreImageDirectory.streamChunk] {
        // Never more than the declared bytes reach the sink.
        var delivered = 0
        do {
          try bad.directory.stream(bad.entry(member), chunkBytes: chunk, read: bad.read) {
            delivered += $0.count
          }
          expect(false, "\(name): streamed at \(chunk)")
        } catch {
          expect(delivered <= bad.entry(member).size, "\(name): \(delivered) bytes delivered")
          expect(error as? RestoreImageDirectory.Failure == .invalidArchive, "\(name): \(error)")
        }
      }
      let badPlan = try bad.plan(planExpected)
      let (base, roots) = try roots()
      defer { try? FileManager.default.removeItem(at: base) }
      let result = write(bad, badPlan, roots)
      if case .success = result { expect(false, "\(name): stub written") }
      let copy = badPlan.copies.first { $0.member == member }!
      let path = (copy.role == "System" ? "" : group + "/") + copy.path
      expect(
        !FileManager.default.fileExists(
          atPath: roots[copy.role]!.appendingPathComponent(path).path),
        "\(name): \(path) published")
      expect(leftovers(base).isEmpty, "\(name): temporary files left")
    }

    // An input budget: a body that needs more input than it allows is refused.
    do {
      let big = try Image(files.appendingPathComponent("big.zip"))
      let iboot = big.entry("Firmware/all_flash/iBoot.j314s.RELEASE.im4p")
      expect(iboot.method == 8 && iboot.compressedSize > 4 * 4096, "big.zip iBoot is deflated")
      for (budget, admits) in [(iboot.compressedSize, true), (iboot.compressedSize - 1, false)] {
        let result = Result {
          try big.directory.stream(iboot, chunkBytes: 4096, maximumInput: budget, read: big.read) {
            _ in
          }
        }
        expect(
          ((try? result.get()) != nil) == admits,
          "input budget \(budget) of \(iboot.compressedSize)")
      }
    }

    // Bad chunk sizes are refused before any read.
    for chunk in [0, -1, (64 << 20) + 1] {
      var reads = 0
      let counted: RestoreImageDirectory.Read = {
        reads += 1
        return try image.read($0, $1)
      }
      expect(
        (try? image.directory.stream(image.entry("Restore.plist"), chunkBytes: chunk, read: counted)
        { _ in }) == nil && reads == 0,
        "chunk \(chunk) refused before any read (\(reads))")
    }

    if failures > 0 {
      print("RestoreImageStubFiles: \(failures) failures")
      exit(1)
    }
    print("RestoreImageStubFiles: \(cases.count) images written (\(written) runs), faults OK")
  }
}
