import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

// RestoreImageStubUpgrade on a fake existing stub (an old restore bundle,
// Recovery image, System files and the restore link, personalized boot/<hash>
// trees, AdminUserRecoveryInfo.plist, the launcher aurora-upgrade armed) with
// the restore images of Fixtures/RestoreImageStubPlan (ok.zip, plain) and
// Fixtures/RestoreImageStubFiles (aea-decode.zip, archives decoded with its
// key). The result is exact: the new bundle at Restore (what a new stub gets),
// the old one at Restore.old, the new Recovery image, the System files
// replaced, SystemVersion where the launcher hid it, and nothing else changed
// (boot/ and the admin metadata above all). The old Recovery image is gone
// before the first byte of the new one is read. A run stopped after every
// step, or by a read failing inside a step, converges on the same tree when
// run again. Refusals before any change (another group, chip, ESP or plan,
// Apple's image not the pinned one, too little space) leave the tree as it
// was, as do another plan's journal and a Restore.old that no run made.
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
  static let fm = FileManager.default

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
    var manifestSHA256: String {
      RecoveryDigest.sha256(try! directory.contents(entry("BuildManifest.plist"), read: read))
    }
  }

  /// Every name under the three roots: a directory, a file's SHA-256 and
  /// mode, or a link's target.
  static func snapshot(_ base: URL) -> [String: String] {
    var out = [String: String]()
    for path in fm.subpaths(atPath: base.path) ?? [] {
      let url = base.appendingPathComponent(path)
      var info = stat()
      guard lstat(url.path, &info) == 0 else { continue }
      switch info.st_mode & S_IFMT {
      case S_IFDIR: out[path] = "dir"
      case S_IFLNK:
        out[path] = "link " + ((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?")
      default:
        out[path] =
          "file \(String(info.st_mode & 0o7777, radix: 8)) "
          + RecoveryDigest.sha256((try? Data(contentsOf: url)) ?? Data())
      }
    }
    return out
  }

  static func directory(_ url: URL) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    var path = url
    while path.path.count > fm.temporaryDirectory.path.count {
      chmod(path.path, 0o755)
      path = path.deletingLastPathComponent()
    }
  }
  static func file(_ url: URL, _ text: String, mode: mode_t = 0o644) throws {
    try directory(url.deletingLastPathComponent())
    try Data(text.utf8).write(to: url)
    chmod(url.path, mode)
  }

  /// Empty System, Preboot and Recovery roots.
  static func roots() throws -> (URL, [String: URL]) {
    let base = fm.temporaryDirectory.appendingPathComponent("stub-upgrade-" + UUID().uuidString)
    var roots = [String: URL]()
    for role in RestoreImageStubFiles.roles {
      roots[role] = base.appendingPathComponent(role)
      try directory(roots[role]!)
    }
    return (base, roots)
  }

  /// An existing stub as aurora-upgrade leaves it: launcher armed,
  /// SystemVersion.plist hidden (or, with `visible`, where an older installer
  /// left it), and the journal directory.
  static func existingStub(visible: Bool = false, link: String? = nil) throws -> (
    URL, [String: URL]
  ) {
    let (base, roots) = try roots()
    let system = roots["System"]!
    let preboot = roots["Preboot"]!.appendingPathComponent(group)
    let recovery = roots["Recovery"]!.appendingPathComponent(group)
    try file(system.appendingPathComponent("usr/standalone/bootcaches.plist"), "old bootcaches")
    try file(
      system.appendingPathComponent("System/Library/CoreServices/PlatformSupport.plist"),
      "old platform support")
    try file(
      system.appendingPathComponent(
        "System/Library/CoreServices/SystemVersion" + (visible ? "" : "-disabled") + ".plist"),
      "old 13.5 version")
    try file(system.appendingPathComponent("System/Library/CoreServices/boot.efi"), "boot.efi")
    try file(system.appendingPathComponent(".IAPhysicalMedia"), "marker")
    try file(system.appendingPathComponent("IAPhysicalMedia-disabled.plist"), "asahi marker")
    try file(
      system.appendingPathComponent("Aurora Installer.app/Contents/Info.plist"), "the app")
    try file(
      system.appendingPathComponent("Aurora/Recovery/UpgradeData/stage1/aura-boot.macho"), "s1")
    try directory(system.appendingPathComponent("Aurora/Recovery/State"))
    chmod(system.appendingPathComponent("Aurora/Recovery/State").path, 0o700)
    try fm.createSymbolicLink(
      atPath: system.appendingPathComponent("Restore").path,
      withDestinationPath: link ?? "/Volumes/Preboot/\(group)/Restore")
    for name in ["BuildManifest.plist", "RestoreVersion.plist", "kernelcache.release.mac14j"] {
      try file(preboot.appendingPathComponent("Restore/" + name), "old " + name)
    }
    try file(preboot.appendingPathComponent("Restore/Bootability/old.txt"), "old bootability")
    for hash in ["A1B2", "C3D4"] {
      try file(
        preboot.appendingPathComponent(
          "boot/\(hash)/System/Library/Caches/com.apple.kernelcaches/kernelcache"),
        "personalized " + hash)
      try file(
        preboot.appendingPathComponent("boot/\(hash)/usr/standalone/firmware/iBoot.img4"), hash)
    }
    try file(
      preboot.appendingPathComponent("var/db/AdminUserRecoveryInfo.plist"), "admins", mode: 0o600)
    try file(
      recovery.appendingPathComponent(RestoreImageStubFiles.recoveryImagePath), "old 13.5 recovery")
    try file(recovery.appendingPathComponent("boot/E5F6/usr/standalone/firmware/iBoot.img4"), "rec")
    return (base, roots)
  }

  static func journal(_ roots: [String: URL]) -> URL {
    roots["System"]!.appendingPathComponent("Aurora/Recovery/State/upgrade.pending.json")
  }

  enum Stop: Error { case here }

  static func run(
    _ image: Image, _ plan: RestoreImageStubPlan, _ roots: [String: URL], key: Data,
    planSHA256: String = String(repeating: "1", count: 64), chunk: Int = 4096,
    read: RestoreImageDirectory.Read? = nil,
    checkpoint: (RestoreImageStubUpgrade.Phase) throws -> Void = { _ in }
  ) -> Result<RestoreImageStubUpgrade.Journal, Error> {
    Result {
      try RestoreImageStubUpgrade.run(
        plan: plan, directory: image.directory, read: read ?? image.read, roots: roots,
        group: group, planSHA256: planSHA256, build: "25G100", journal: journal(roots),
        chunkBytes: chunk, archiveKey: { _, _ in key }, checkpoint: checkpoint)
    }
  }

  static func main() throws {
    umask(0o077)
    let planExpected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: plans.appendingPathComponent("expected.json"))) as! [String: Any]
    let filesExpected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: files.appendingPathComponent("expected.json"))) as! [String: Any]
    let aeaKey: Data = {
      let text = (filesExpected["aea-decode"] as! [String: Any])["key"] as! String
      return Data(
        stride(from: 0, to: text.count, by: 2).map {
          UInt8(text.dropFirst($0).prefix(2), radix: 16)!
        })
    }()
    func makePlan(_ image: Image, build: String? = nil, size: Int? = nil) throws
      -> RestoreImageStubPlan
    {
      try RestoreImageStubPlan(
        directory: image.directory, read: image.read,
        productVersion: planExpected["version"] as! String,
        deviceClass: planExpected["device_class"] as! String,
        boardID: UInt64(planExpected["board"] as! Int),
        chipID: UInt64(planExpected["chip"] as! Int),
        pin: .init(
          sourceBytes: size ?? image.bytes.count, manifestSHA256: image.manifestSHA256,
          build: build ?? planExpected["build"] as! String),
        sha256: RecoveryDigest.sha256)
    }
    var converged = 0

    for (name, url) in [
      ("ok", plans.appendingPathComponent("ok.zip")),
      ("aea-decode", files.appendingPathComponent("aea-decode.zip")),
    ] {
      let image = try Image(url)
      let plan = try makePlan(image)

      // What a new stub gets from the same plan.
      let (freshBase, freshRoots) = try roots()
      defer { try? fm.removeItem(at: freshBase) }
      let fresh = try RestoreImageStubFiles(
        plan: plan, directory: image.directory, read: image.read, roots: freshRoots, group: group,
        chunkBytes: 4096, archiveKey: { _, _ in aeaKey })
      expect(fresh.pending.isEmpty, "\(name): a fresh stub has nothing pending")
      let freshTree = snapshot(freshBase)

      // The tree an upgrade must leave: everything as it was except the new
      // bundle at Restore, the old one at Restore.old, the new Recovery
      // image, the System files, the stub version where it was, the journal.
      func expectedTree(_ before: [String: String], visible: Bool) -> [String: String] {
        var want = before
        let restore = "Preboot/\(group)/Restore"
        for (path, value) in before where path == restore || path.hasPrefix(restore + "/") {
          want.removeValue(forKey: path)
          want[restore + ".old" + path.dropFirst(restore.count)] = value
        }
        for (path, value) in freshTree {
          if path == restore || path.hasPrefix(restore + "/") || path.hasPrefix("Recovery/") {
            want[path] = value
          } else if path.hasPrefix("System/") {
            let mapped =
              path.hasSuffix("SystemVersion.plist") && !visible
              ? path.replacingOccurrences(
                of: "SystemVersion.plist", with: "SystemVersion-disabled.plist")
              : path
            want[mapped] = value
          }
        }
        return want
      }

      for visible in [false, true] {
        let (base, roots) = try existingStub(visible: visible)
        defer { try? fm.removeItem(at: base) }
        let before = snapshot(base)
        // The old Recovery image is gone before the new one's first byte is read.
        let recoveryStart = try image.directory.dataOffset(plan.recoveryMember, read: image.read)
        let oldImage = roots["Recovery"]!.appendingPathComponent(
          group + "/" + RestoreImageStubFiles.recoveryImagePath)
        var orderChecked = false
        let watched: RestoreImageDirectory.Read = { offset, count in
          if offset + count > recoveryStart,
            offset < recoveryStart + plan.recoveryMember.compressedSize
          {
            let content = try? Data(contentsOf: oldImage)
            expect(
              content != Data("old 13.5 recovery".utf8),
              "\(name): the old Recovery image is still there while the new one is read")
            orderChecked = true
          }
          return try image.read(offset, count)
        }
        guard case .success(let journal) = run(image, plan, roots, key: aeaKey, read: watched)
        else {
          expect(false, "\(name): upgrade: \(run(image, plan, roots, key: aeaKey))")
          continue
        }
        expect(orderChecked, "\(name): the Recovery image was read")
        expect(journal.phase == .systemWritten, "\(name): phase \(journal.phase)")
        var after = snapshot(base)
        let journalPath = "System/Aurora/Recovery/State/upgrade.pending.json"
        expect(after.removeValue(forKey: journalPath) != nil, "\(name): journal kept")
        let want = expectedTree(before, visible: visible)
        for key in Set(want.keys).union(after.keys).sorted() where want[key] != after[key] {
          expect(
            false,
            "\(name) visible=\(visible): \(key): \(after[key] ?? "absent"), want \(want[key] ?? "absent")"
          )
        }
        // boot/ and the admin metadata are byte for byte what they were.
        for (path, value) in before
        where path.contains("/boot/") || path.hasSuffix("AdminUserRecoveryInfo.plist") {
          expect(after[path] == value, "\(name): \(path) changed")
        }
        // The receipts: a new stub's, the restore link last.
        let link = journal.installed.last
        expect(
          link?.path == "Restore" && link?.linkTarget == "/Volumes/Preboot/\(group)/Restore",
          "\(name): the old restore link to the group's Restore is kept: \(String(describing: link))"
        )
        let receipts = Set(
          journal.installed.dropLast().map { "\($0.role) \($0.path) \($0.identity.sha256)" })
        let freshReceipts = Set(
          fresh.installed.map { "\($0.role) \($0.path) \($0.identity.sha256)" })
        expect(receipts == freshReceipts, "\(name): receipts are a new stub's")
        // Run again: nothing to do, the same tree.
        let again = run(image, plan, roots, key: aeaKey)
        expect((try? again.get()) == journal, "\(name): a finished run again: \(again)")
        var afterAgain = snapshot(base)
        afterAgain.removeValue(forKey: journalPath)
        expect(afterAgain == after, "\(name): a finished run again changed the tree")
      }

      // A restore link elsewhere is pointed at this Preboot's group Restore.
      do {
        let (base, roots) = try existingStub(link: "/somewhere/else")
        defer { try? fm.removeItem(at: base) }
        let journal = try run(image, plan, roots, key: aeaKey).get()
        let target = roots["Preboot"]!.appendingPathComponent(group + "/Restore").path
        expect(
          (try? fm.destinationOfSymbolicLink(
            atPath: roots["System"]!.appendingPathComponent("Restore").path))
            == target && journal.installed.last?.linkTarget == target,
          "\(name): a foreign restore link is replaced")
      }

      // Stopped after each step, or by a read failing inside one: the next
      // run converges on the same tree.
      let (referenceBase, referenceRoots) = try existingStub()
      defer { try? fm.removeItem(at: referenceBase) }
      _ = try run(image, plan, referenceRoots, key: aeaKey).get()
      let reference = snapshot(referenceBase)
      let phases: [RestoreImageStubUpgrade.Phase] = [
        .started, .prebootWritten, .prebootSwapped, .recoveryRemoved, .recoveryWritten,
      ]
      var stops: [(String, RestoreImageDirectory.Read?, RestoreImageStubUpgrade.Phase?)] =
        phases.map { ("after \($0)", nil, $0) }
      for limit in [3, 40, 90, 160] {
        var reads = 0
        stops.append(
          (
            "read \(limit) fails",
            { offset, count in
              reads += 1
              if reads == limit { throw Stop.here }
              return try image.read(offset, count)
            }, nil
          ))
      }
      for (what, read, phase) in stops {
        let (base, roots) = try existingStub()
        defer { try? fm.removeItem(at: base) }
        let first = run(image, plan, roots, key: aeaKey, read: read) {
          if $0 == phase { throw Stop.here }
        }
        if case .success = first {
          // A read limit past the run's last read: nothing to stop.
          expect(read != nil, "\(name): \(what): not stopped")
        }
        var stopped = snapshot(base)
        stopped.removeValue(forKey: "System/Aurora/Recovery/State/upgrade.pending.json")
        // Linux still starts: the old personalized boot files are untouched at every stop.
        for (path, value) in reference where path.contains("/boot/") {
          expect(stopped[path] == value, "\(name): \(what): \(path) changed")
        }
        let second = run(image, plan, roots, key: aeaKey)
        expect((try? second.get())?.phase == .systemWritten, "\(name): \(what): rerun: \(second)")
        let tree = snapshot(base)
        let differs = Set(tree.keys).union(reference.keys).filter { tree[$0] != reference[$0] }
        expect(differs.isEmpty, "\(name): \(what): rerun differs at \(differs.sorted().prefix(5))")
        let leftovers = tree.keys.filter {
          $0.split(separator: "/").last?.hasPrefix(".aurora-stub-") == true
        }
        expect(leftovers.isEmpty, "\(name): \(what): temporary files left: \(leftovers)")
        converged += 1
      }

      // Refusals leave the stub as it was.
      func unchanged(
        _ what: String, setup: ([String: URL]) throws -> Void = { _ in },
        body: ([String: URL]) throws -> Void
      ) throws {
        let (base, roots) = try existingStub()
        defer { try? fm.removeItem(at: base) }
        try setup(roots)
        let before = snapshot(base)
        do {
          try body(roots)
          expect(false, "\(name): \(what): not refused")
        } catch {}
        expect(snapshot(base) == before, "\(name): \(what): the stub changed")
      }
      try unchanged(
        "another plan's journal",
        setup: { roots in
          var other = RestoreImageStubUpgrade.Journal(
            planSHA256: String(repeating: "2", count: 64), group: group, build: "25G100")
          other.phase = .recoveryRemoved
          try other.save(journal(roots))
        },
        body: { roots in
          let result = run(image, plan, roots, key: aeaKey)
          expect(
            (result.failure as? RestoreImageStubUpgrade.Failure) == .otherJournal,
            "\(name): another plan's journal: \(result)")
          _ = try result.get()
        })
      try unchanged(
        "a Restore.old no run made",
        setup: { roots in
          try directory(roots["Preboot"]!.appendingPathComponent(group + "/Restore.old"))
        },
        body: { roots in
          let result = run(image, plan, roots, key: aeaKey)
          expect(
            (result.failure as? RestoreImageStubUpgrade.Failure) == .foreignState,
            "\(name): a foreign Restore.old: \(result)")
          _ = try result.get()
        })
      try unchanged(
        "a Restore.new no run made",
        setup: { roots in
          try file(roots["Preboot"]!.appendingPathComponent(group + "/Restore.new/x"), "x")
        },
        body: { roots in
          _ = try run(image, plan, roots, key: aeaKey).get()
        })
      try unchanged("no archive key") { roots in
        try RestoreImageStubUpgrade.run(
          plan: plan, directory: image.directory, read: image.read, roots: roots, group: group,
          planSHA256: String(repeating: "1", count: 64), build: "25G100", journal: journal(roots),
          archiveKey: nil)
      }

      // The checks before any change, with this image as Apple's: a request
      // for it passes; another group, chip, ESP, plan, pin or too little
      // space is refused and the stub stays as it was.
      let template =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf: here.appendingPathComponent("Fixtures/StubUpgrade/upgrade-config.json")))
        as! [String: Any]
      let stage1 = Data("stage 1".utf8)
      func request(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var object = template
        object["board"] = String((planExpected["device_class"] as! String).dropLast(2))
        object["chip"] = "0x" + String(planExpected["chip"] as! Int, radix: 16)
        var target = object["target"] as! [String: Any]
        target["version"] = planExpected["version"]
        target["build"] = planExpected["build"]
        target["source_bytes"] = image.bytes.count
        target["manifest_sha256"] = "sha256:" + image.manifestSHA256
        object["target"] = target
        var s1 = object["stage1"] as! [String: Any]
        s1["sha256"] = RecoveryDigest.sha256(stage1)
        object["stage1"] = s1
        // Linux's measures below this image's, so the plan's sizes count.
        var space = object["space"] as! [String: Any]
        space["new_recovery_image"] = 1
        space["new_boot_files"] = 1
        object["space"] = space
        change(&object)
        object.removeValue(forKey: "plan_sha256")
        object["plan_sha256"] = RecoveryDigest.sha256(
          Data(StubUpgradeRequest.pythonJSON(object)!.utf8))
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      }
      let config = request()
      let decoded = try StubUpgradeRequest.decode(config)
      let facts = StubUpgradeFacts(
        group: group, chipID: decoded.chipID, deviceClass: decoded.deviceClass,
        espPartitionUUID: decoded.espPartitionUUID, espRequest: config,
        stubInfo: try JSONSerialization.data(withJSONObject: ["vgid": group]),
        espFreeBytes: 200 << 20, systemFirmware: "iBoot-13822.41.1", stage1: stage1,
        containerFreeBytes: 1 << 30, recoveryImageBytes: 1 << 20,
        systemRecovery: "26.2.123.0.0,0",
        systemVersionVisible: false, systemVersionHidden: true, launchedByMarker: true)
      /// The whole Recovery sequence up to the files: checks, plan, space, write.
      func upgrade(
        _ roots: [String: URL], config: Data, facts: StubUpgradeFacts, sourceBytes: Int? = nil
      ) throws {
        let request = try StubUpgradeCheck.verify(config: config, facts: facts)
        let served = try RestoreImageDirectory.read(archiveSize: sourceBytes ?? image.bytes.count) {
          try image.read($0, $1)
        }
        let plan = try StubUpgradeCheck.plan(
          request, directory: served, read: image.read,
          boardID: UInt64(planExpected["board"] as! Int))
        try StubUpgradeCheck.verify(
          plan: plan, request: request, stage1Bytes: stage1.count,
          freeBytes: facts.containerFreeBytes, phase: nil)
        try RestoreImageStubUpgrade.run(
          plan: plan, directory: served, read: image.read, roots: roots, group: request.group,
          planSHA256: request.planSHA256, build: request.target.build, journal: journal(roots),
          archiveKey: { _, _ in aeaKey })
      }
      do {
        let (base, roots) = try existingStub()
        defer { try? fm.removeItem(at: base) }
        try upgrade(roots, config: config, facts: facts)
        let tree = snapshot(base).filter { !$0.key.hasSuffix("upgrade.pending.json") }
        let files = reference.filter { !$0.key.hasSuffix("upgrade.pending.json") }
        let differs = Set(tree.keys).union(files.keys).filter { tree[$0] != files[$0] }
        expect(differs.isEmpty, "\(name): the checked upgrade differs at \(differs.sorted())")
      } catch {
        expect(false, "\(name): checked upgrade: \(error)")
      }
      func refused(
        _ what: String, _ want: StubUpgradeCheck.Refusal, config: Data? = nil,
        sourceBytes: Int? = nil, _ change: (inout StubUpgradeFacts) -> Void = { _ in }
      ) throws {
        var changed = facts
        change(&changed)
        try unchanged(what) { roots in
          do {
            try upgrade(
              roots, config: config ?? request(), facts: changed, sourceBytes: sourceBytes)
          } catch {
            expect(
              error as? StubUpgradeCheck.Refusal == want, "\(name): \(what): \(error), want \(want)"
            )
            throw error
          }
        }
      }
      try refused("another group", .otherVolume) {
        $0.group = "7A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8"
      }
      try refused("another chip", .otherMac) { $0.chipID = 0x8112 }
      try refused("another ESP", .otherPartition) {
        $0.espPartitionUUID = "2b2c3d4e-5f60-4172-8394-a5b6c7d8e9f0"
      }
      let otherPlan = request { $0["system_firmware"] = "iBoot-1.2.3" }
      try refused("another plan on the ESP", .requestDiffers, config: otherPlan)
      try refused(
        "a plan hash that isn't the plan's", .notStaged,
        config: {
          var object = try! JSONSerialization.jsonObject(with: config) as! [String: Any]
          object["plan_sha256"] = String(repeating: "0", count: 64)
          return try! JSONSerialization.data(withJSONObject: object)
        }()
      ) { $0.espRequest = nil }
      let otherBuild = request {
        var target = $0["target"] as! [String: Any]
        target["build"] = "25G101"
        $0["target"] = target
      }
      try refused("another build pinned", .imageDiffers, config: otherBuild) {
        $0.espRequest = otherBuild
      }
      let otherManifest = request {
        var target = $0["target"] as! [String: Any]
        target["manifest_sha256"] = "sha256:" + String(repeating: "0", count: 64)
        $0["target"] = target
      }
      try refused("another manifest pinned", .imageDiffers, config: otherManifest) {
        $0.espRequest = otherManifest
      }
      let otherSize = request {
        var target = $0["target"] as! [String: Any]
        target["source_bytes"] = image.bytes.count + 1
        $0["target"] = target
      }
      try refused("another image size pinned", .imageDiffers, config: otherSize) {
        $0.espRequest = otherSize
      }
      // The space: aurora-upgrade's peak less what is used now, from this
      // plan's sizes: the Recovery image and 1/16, three copies of the boot
      // files (the restore bundle and bless's two), the Stage 1 twice. The
      // old Recovery image is never counted as freed.
      let bundle = plan.copies.filter { $0.role == "Preboot" }.reduce(plan.manifest.count) {
        $0 + image.entry($1.member).size
      }
      let member = plan.recoveryMember.size
      let need = StubUpgradeCheck.neededBytes(
        plan: plan, request: decoded, stage1Bytes: stage1.count, phase: nil)
      expect(
        need == UInt64(3 * bundle + member + member / 16 + 2 * stage1.count),
        "\(name): need \(need)")
      try refused("too little space", .space(need: need, free: need - 1)) {
        $0.containerFreeBytes = need - 1
      }
      expect(
        (try? StubUpgradeCheck.verify(
          plan: plan, request: decoded, stage1Bytes: stage1.count, freeBytes: need, phase: nil))
          != nil, "\(name): exactly enough space passes")
      // Linux's larger measures win: never less safe than its peak.
      let linux = try StubUpgradeRequest.decode(
        request {
          var space = $0["space"] as! [String: Any]
          space["new_recovery_image"] = 1_600_000_000
          space["new_boot_files"] = 300_000_000
          $0["space"] = space
        })
      expect(
        StubUpgradeCheck.neededBytes(plan: plan, request: linux, stage1Bytes: 0, phase: nil)
          == 1_600_000_000 + 100_000_000 + 3 * 300_000_000,
        "\(name): Linux's measures count when larger")
      // A rerun counts only what is still to come.
      for (phase, want) in [
        (RestoreImageStubUpgrade.Phase.prebootWritten, need - UInt64(bundle)),
        (.recoveryWritten, UInt64(2 * bundle + 2 * stage1.count)),
        (.systemWritten, UInt64(2 * bundle + 2 * stage1.count)),
        (.blessed, UInt64(2 * stage1.count)), (.enrolled, 0),
      ] {
        expect(
          StubUpgradeCheck.neededBytes(
            plan: plan, request: decoded, stage1Bytes: stage1.count, phase: phase) == want,
          "\(name): need after \(phase)")
      }
    }

    if failures > 0 {
      print("RestoreImageStubUpgrade: \(failures) failures")
      exit(1)
    }
    print(
      "RestoreImageStubUpgrade: in place exact, \(converged) interrupted runs converged, refusals unchanged"
    )
  }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
