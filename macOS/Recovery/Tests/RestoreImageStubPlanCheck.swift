import Foundation

// RestoreImageStubPlan and RestoreImageDirectory against the reference in
// Fixtures/RestoreImageStubPlan (generate.py, also read by the main
// installer's NativeStubFileTests) and against the main installer's own
// stub vectors (native-stub-files.json), plus the pin and broken bodies.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }

  static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  static let fixtures = here.appendingPathComponent("Fixtures/RestoreImageStubPlan")

  struct Image {
    let bytes: [UInt8]
    func read(_ offset: Int, _ count: Int) throws -> Data {
      Data(bytes[offset..<(offset + count)])
    }
  }

  /// The pin a sealed installation would carry for `image`.
  static func pin(_ image: Image, build: String) throws -> RestoreImageStubPlan.Pin {
    let directory = try RestoreImageDirectory.read(archiveSize: image.bytes.count, read: image.read)
    let manifest = try directory.contents(
      directory.entries.first { $0.name == "BuildManifest.plist" }!, read: image.read)
    return .init(
      sourceBytes: image.bytes.count, manifestSHA256: RecoveryDigest.sha256(manifest), build: build)
  }

  static func plan(
    _ image: Image, version: String, deviceClass: String, board: UInt64, chip: UInt64,
    pin: RestoreImageStubPlan.Pin
  ) throws -> RestoreImageStubPlan {
    let directory = try RestoreImageDirectory.read(archiveSize: image.bytes.count, read: image.read)
    return try RestoreImageStubPlan(
      directory: directory, read: image.read, productVersion: version, deviceClass: deviceClass,
      boardID: board, chipID: chip, pin: pin, sha256: RecoveryDigest.sha256)
  }

  static func main() throws {
    let expected =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("expected.json"))) as! [String: Any]
    let board = UInt64(expected["board"] as! Int)
    let chip = UInt64(expected["chip"] as! Int)
    let deviceClass = expected["device_class"] as! String
    let version = expected["version"] as! String
    let build = expected["build"] as! String
    // The shared cases, which NativeStubFileTests also runs, and the cases
    // where Recovery's byte-wise prefixes select what the main installer's
    // Character prefixes skip.
    let cases = (expected["cases"] as! [String: Any]).merging(
      expected["recovery_only"] as! [String: Any]
    ) { shared, _ in shared }
    expect(cases.count >= 26, "fixture cases: \(cases.count)")
    var images = [String: Image]()
    for (name, want) in cases.sorted(by: { $0.key < $1.key }) {
      let image = Image(
        bytes: [UInt8](try Data(contentsOf: fixtures.appendingPathComponent(name + ".zip"))))
      images[name] = image
      // A refused image may not even yield a manifest for its pin.
      let imagePin =
        (try? pin(image, build: build))
        ?? .init(sourceBytes: image.bytes.count, manifestSHA256: "", build: build)
      let result = Result {
        try plan(
          image, version: version, deviceClass: deviceClass, board: board, chip: chip,
          pin: imagePin)
      }
      guard let want = want as? [String: Any] else {
        if case .success = result { expect(false, "\(name): plan admitted, reference refuses") }
        continue
      }
      guard case .success(let plan) = result else {
        expect(false, "\(name): refused, reference admits: \(result)")
        continue
      }
      let copies = (want["copies"] as! [[String: Any]]).map {
        RestoreImageStubPlan.Copy(
          member: $0["member"] as! String, role: $0["role"] as! String,
          path: $0["path"] as! String, installerDataName: $0["installerDataName"] as? String)
      }
      expect(plan.copies == copies, "\(name): copies differ:\n\(plan.copies)\n\(copies)")
      expect(
        plan.linkTargets == want["links"] as! [String: String],
        "\(name): links \(plan.linkTargets)")
      expect(plan.restorePath == want["restorePath"] as! String, "\(name): \(plan.restorePath)")
      expect(plan.recoveryMember.name == want["recovery"] as! String, "\(name): recovery member")
      // Each member is read once, links never as files, the Recovery image
      // last.
      var once = Set<String>()
      expect(
        plan.readMembers.map(\.name)
          == (copies.filter { plan.linkTargets[$0.member] == nil }.map(\.member)
          + [plan.recoveryMember.name]).filter { once.insert($0).inserted },
        "\(name): read members")
      let document =
        try PropertyListSerialization.propertyList(from: plan.manifest, format: nil)
        as! [String: Any]
      let identities = document["BuildIdentities"] as! [[String: Any]]
      expect(
        identities.count == 1 && identities[0]["ApBoardID"] as? String == "0x22"
          && (identities[0]["Info"] as! [String: Any])["Variant"] as? String == "macOS Customer",
        "\(name): manifest keeps only this Mac's identity")
      let system =
        try PropertyListSerialization.propertyList(from: plan.systemVersion, format: nil)
        as! [String: Any]
      expect(
        system["ProductUserVisibleVersion"] as? String == version + " (stub)"
          && system["ProductVersion"] as? String == version,
        "\(name): stub system version")
      let info = try JSONSerialization.jsonObject(with: plan.stubInfo) as! [String: Any]
      let manifestInfo = info["manifest_info"] as! [String: String]
      expect(
        manifestInfo == [
          "build_number": build, "variant": "macOS Customer", "device_class": deviceClass,
          "board_id": "0x22", "chip_id": "0x6000",
        ] && (info["system_version"] as? [String: Any])?["ProductVersion"] as? String == version,
        "\(name): stub info \(info)")
    }

    // The pin: the image's size, its manifest and the build it names.
    let ok = images["ok"]!
    let good = try pin(ok, build: build)
    func refusesPin(_ pin: RestoreImageStubPlan.Pin, _ what: String) {
      do {
        _ = try plan(
          ok, version: version, deviceClass: deviceClass, board: board, chip: chip, pin: pin)
        expect(false, "pin \(what): admitted")
      } catch let error as RestoreImageStubPlan.Failure {
        expect(error == .pinMismatch, "pin \(what): \(error)")
      } catch {
        expect(false, "pin \(what): \(error)")
      }
    }
    refusesPin(
      .init(
        sourceBytes: good.sourceBytes + 1, manifestSHA256: good.manifestSHA256, build: build),
      "size")
    refusesPin(
      .init(
        sourceBytes: good.sourceBytes, manifestSHA256: String(repeating: "0", count: 64),
        build: build), "manifest")
    refusesPin(
      .init(sourceBytes: good.sourceBytes, manifestSHA256: good.manifestSHA256, build: "25G101"),
      "build")
    do {
      _ = try plan(
        images["update-archive"]!, version: version, deviceClass: deviceClass, board: board,
        chip: chip, pin: good)
      expect(false, "update archive admitted")
    } catch let error as RestoreImageStubPlan.Failure {
      expect(error == .updateArchive, "update archive: \(error)")
    }

    // A deflated body or a link that doesn't decode to its length and
    // CRC-32 is refused, whichever byte breaks.
    let directory = try RestoreImageDirectory.read(archiveSize: ok.bytes.count, read: ok.read)
    for name in [
      "BuildManifest.plist", "SystemVersion.plist",
      "BootabilityBundle/Restore/Bootability/Frameworks/Boot.framework/Boot",
    ] {
      let entry = directory.entries.first { $0.name == name }!
      let link = entry.isSymbolicLink
      let offset = try directory.dataOffset(entry, symbolicLink: link, read: ok.read)
      var refused = 0
      for at in 0..<entry.compressedSize {
        var bytes = ok.bytes
        bytes[offset + at] ^= 0x01
        let broken = Image(bytes: bytes)
        if (try? directory.contents(entry, symbolicLink: link, read: broken.read)) == nil {
          refused += 1
        }
      }
      expect(refused == entry.compressedSize, "\(name): \(refused)/\(entry.compressedSize) refused")
    }
    // A link is not a file, and a file is not a link.
    let boot = directory.entries.first { $0.name.hasSuffix("Boot.framework/Boot") }!
    let manifestEntry = directory.entries.first { $0.name == "BuildManifest.plist" }!
    expect((try? directory.contents(boot, read: ok.read)) == nil, "link read as a file")
    expect((try? directory.linkTarget(manifestEntry, read: ok.read)) == nil, "file read as a link")
    expect(
      (try? directory.linkTarget(boot, read: ok.read)) == "Versions/Current/Boot", "link target")

    // Faults the directory itself refuses, before any plan: a name that
    // climbs, a name twice, a local header naming another file, a deflate
    // stream with bytes after its end, a link target that climbs.
    for name in ["component-climbs", "duplicate-name"] {
      expect(
        (try? RestoreImageDirectory.read(
          archiveSize: images[name]!.bytes.count, read: images[name]!.read)) == nil,
        "\(name): directory admitted")
    }
    var renamed = ok.bytes
    renamed[manifestEntry.localHeader + 30] ^= 0x20
    expect(
      (try? directory.contents(manifestEntry, read: Image(bytes: renamed).read)) == nil,
      "local header names another file")
    let deflated = try RestoreImageMember.exact(
      directory.dataOffset(manifestEntry, read: ok.read), manifestEntry.compressedSize,
      archiveSize: ok.bytes.count, read: ok.read)
    expect(
      (try? RestoreImageDirectory.inflate(deflated, size: manifestEntry.size)) != nil,
      "deflate stream decodes")
    expect(
      (try? RestoreImageDirectory.inflate(deflated + [0], size: manifestEntry.size)) == nil,
      "bytes after the deflate stream")
    let climbs = images["link-climbs"]!
    let climbing = try RestoreImageDirectory.read(
      archiveSize: climbs.bytes.count, read: climbs.read)
    expect(
      (try? climbing.linkTarget(
        climbing.entries.first { $0.name.hasSuffix("Boot.framework/Boot") }!, read: climbs.read))
        == nil, "link target climbs")
    // Names and link targets must be valid UTF-8: a stray byte, an overlong
    // form, a surrogate or a cut sequence is refused, not replaced.
    for bad: [UInt8] in [[0x61, 0xff], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0x61, 0xe2, 0x82]] {
      expect(RestoreImageDirectory.utf8(bad) == nil, "invalid UTF-8 \(bad) admitted")
    }
    for good in ["Restore.plist", "a/\u{301}b", "\u{1F600}"] {
      expect(RestoreImageDirectory.utf8(Array(good.utf8)) == good, "UTF-8 \(good) refused")
    }

    // A central directory over the main installer's 8 MiB (129 entries with
    // 65535-byte comments) is refused; the same entries with short comments
    // are admitted.
    func padded(comment: Int) -> (image: Image, directoryBytes: Int) {
      func le(_ value: Int, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
      }
      var bytes = [UInt8]()
      var central = [UInt8]()
      for index in 0..<129 {
        let name = Array("pad/\(index)".utf8)
        let at = bytes.count
        let crc = le(0x8207_9eb1, 4)  // CRC-32 of "p"
        bytes +=
          le(0x0403_4b50, 4) + le(20, 2) + le(0, 4) + le(0, 4) + crc + le(1, 4) + le(1, 4)
          + le(name.count, 2) + le(0, 2) + name + [UInt8(ascii: "p")]
        central +=
          le(0x0201_4b50, 4) + le(0x0314, 2) + le(20, 2) + le(0, 4) + le(0, 4) + crc
          + le(1, 4) + le(1, 4) + le(name.count, 2) + le(0, 2) + le(comment, 2) + le(0, 4)
          + le(0o100644 << 16, 4) + le(at, 4) + name + [UInt8](repeating: 0x63, count: comment)
      }
      let start = bytes.count
      bytes +=
        central + le(0x0605_4b50, 4) + le(0, 4) + le(129, 2) + le(129, 2)
        + le(central.count, 4) + le(start, 4) + le(0, 2)
      return (Image(bytes: bytes), central.count)
    }
    let over = padded(comment: 65535)
    let under = padded(comment: 16)
    expect(over.directoryBytes > 8 << 20, "directory size \(over.directoryBytes)")
    expect(
      (try? RestoreImageDirectory.read(archiveSize: over.image.bytes.count, read: over.image.read))
        == nil, "directory over 8 MiB admitted")
    let small = try? RestoreImageDirectory.read(
      archiveSize: under.image.bytes.count, read: under.image.read)
    expect(small?.entries.count == 129, "short-comment directory refused")
    if let small, let first = small.entries.first {
      expect(
        (try? small.contents(first, read: under.image.read)) == Data("p".utf8),
        "short-comment directory member")
    }

    // The main installer's own stub vectors: same board, chip and class as
    // its NativeStubFileTests, and the same verdict for each.
    let vectors =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: here.appendingPathComponent(
            "../../Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/native-stub-files.json")))
      as! [String: Any]
    var seen = 0
    for vector in vectors["vectors"] as! [[String: Any]] {
      let name = vector["name"] as! String
      let image = Image(bytes: [UInt8](Data(base64Encoded: vector["archive"] as! String)!))
      let vectorPin =
        (try? pin(image, build: "")) ?? .init(sourceBytes: 0, manifestSHA256: "", build: "")
      // The vectors' build number is the manifest's own.
      let admitted: Bool = {
        guard
          let directory = try? RestoreImageDirectory.read(
            archiveSize: image.bytes.count, read: image.read),
          let manifest = directory.entries.first(where: { $0.name == "BuildManifest.plist" }),
          let data = try? directory.contents(manifest, read: image.read),
          let document = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
          let identities = document["BuildIdentities"] as? [[String: Any]]
        else { return false }
        return identities.contains { identity in
          let build = (identity["Info"] as? [String: Any])?["BuildNumber"] as? String ?? ""
          return
            (try? plan(
              image, version: "26.6.2", deviceClass: "j700ap", board: 1, chip: 2,
              pin: .init(
                sourceBytes: vectorPin.sourceBytes, manifestSHA256: vectorPin.manifestSHA256,
                build: build))) != nil
        }
      }()
      expect(admitted == vector["success"] as! Bool, "main vector \(name): admitted \(admitted)")
      seen += 1
    }
    expect(seen >= 2, "main vectors: \(seen)")

    if failures > 0 {
      print("\(failures) failure(s)")
      exit(1)
    }
    print("RestoreImageStubPlan: \(cases.count) reference images, \(seen) main vectors, OK")
  }
}
