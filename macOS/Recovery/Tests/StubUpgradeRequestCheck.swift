import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// StubUpgradeRequest against what aurora-upgrade itself writes
// (Fixtures/StubUpgrade, generate.py: Plan.to_json and its plan_sha256, one
// with a caution in non-ASCII text), StubUpgradeCheck's refusals before any
// change, the version rule aurora-upgrade ports from the installer, the
// Stage 1 fill for an EFI partition, and the owner of a stub without a
// recorded bootstrap.
struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }

  static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  static let fixtures = here.appendingPathComponent("Fixtures/StubUpgrade")

  /// `object` re-signed as aurora-upgrade would sign it, in its layout.
  static func signed(_ object: [String: Any]) -> Data {
    var object = object
    object.removeValue(forKey: "plan_sha256")
    object["plan_sha256"] = RecoveryDigest.sha256(
      Data(StubUpgradeRequest.pythonJSON(object)!.utf8))
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func main() throws {
    let config = try Data(contentsOf: fixtures.appendingPathComponent("upgrade-config.json"))
    let caution = try Data(contentsOf: fixtures.appendingPathComponent("caution.json"))
    let object = try JSONSerialization.jsonObject(with: config) as! [String: Any]

    // aurora-upgrade's own output decodes, digest and all.
    do {
      let request = try StubUpgradeRequest.decode(config)
      expect(request.group == "6A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8", "group")
      expect(request.chipID == 0x8112 && request.board == "j413", "chip and board")
      expect(request.deviceClass == "j413ap", "device class")
      expect(request.espPartitionUUID == "1b2c3d4e-5f60-4172-8394-a5b6c7d8e9f0", "ESP")
      expect(request.target.build == "26B123" && request.target.version == "27.2", "target")
      expect(request.target.manifestSHA256 == String(repeating: "ab", count: 32), "manifest hash")
      expect(request.target.sourceBytes == 19_000_000_000, "image size")
      expect(request.currentBuild == "20G75" && request.currentVersion == "13.5", "current")
      expect(request.space.peak == 2_346_870_912, "peak")
      expect(request.stage1Path == "stage1/aura-boot.macho", "Stage 1 path")
    } catch {
      expect(false, "the fixture: \(error)")
    }
    do {
      let request = try StubUpgradeRequest.decode(caution)
      expect(request.target.caution.contains("\u{1F512}"), "caution text")
    } catch {
      expect(false, "the caution fixture: \(error)")
    }

    // Any change to a signed field breaks the digest; a re-signed change of
    // shape is refused as invalid.
    func refused(_ what: String, _ want: StubUpgradeRequest.Failure, _ data: Data) {
      do {
        _ = try StubUpgradeRequest.decode(data)
        expect(false, "\(what): decoded")
      } catch {
        expect(error as? StubUpgradeRequest.Failure == want, "\(what): \(error), want \(want)")
      }
    }
    var text = String(decoding: config, as: UTF8.self)
    text = text.replacingOccurrences(of: "\"26B123\"", with: "\"26B124\"")
    refused("a changed build", .digest, Data(text.utf8))
    var changed = object
    changed["esp_partuuid"] = "2b2c3d4e-5f60-4172-8394-a5b6c7d8e9f0"
    var unsigned = changed
    unsigned["plan_sha256"] = object["plan_sha256"]
    refused(
      "a changed ESP with the old digest", .digest,
      try JSONSerialization.data(withJSONObject: unsigned))
    expect((try? StubUpgradeRequest.decode(signed(changed))) != nil, "a re-signed request")
    for (key, value) in [
      ("mode", "slot" as Any), ("schema", 2), ("chip", "8112"), ("chip", "0x08112"),
      ("board", "J413"), ("esp_partuuid", "not-a-uuid"), ("extra", 1),
    ] {
      var bad = object
      bad[key] = value
      refused("\(key) = \(value)", .invalid, signed(bad))
    }
    for url in [
      "http://updates.cdn-apple.com/x.ipsw", "https://example.com/x.ipsw",
      "https://updates.cdn-apple.com:8443/x.ipsw", "https://updates.cdn-apple.com/x.ipsw?a=1",
    ] {
      var bad = object
      var target = bad["target"] as! [String: Any]
      target["url"] = url
      bad["target"] = target
      refused("image URL \(url)", .invalid, signed(bad))
    }
    var noPrefix = object
    var target = noPrefix["target"] as! [String: Any]
    target["manifest_sha256"] = String(repeating: "ab", count: 32)
    noPrefix["target"] = target
    refused("a manifest hash without sha256:", .invalid, signed(noPrefix))
    refused("not JSON", .invalid, Data("{".utf8))
    refused("too large", .invalid, Data(repeating: 0x20, count: 65537))

    // Python's json.dumps(sort_keys=True), byte for byte.
    let sample: [String: Any] = ["b": 1, "a": ["x\u{7f}", "\u{e9}\n"], "B": [String: Any]()]
    let dumped = StubUpgradeRequest.pythonJSON(sample)
    expect(
      dumped == #"{"B": {}, "a": ["x\u007f", "\u00e9\n"], "b": 1}"#,
      "python JSON: \(dumped ?? "-")")
    expect(StubUpgradeRequest.pythonJSON(["a": 1.5]) == nil, "a fraction is refused")

    // The checks before any change.
    let request = try StubUpgradeRequest.decode(config)
    let stage1 = Data("stage 1".utf8)
    var withStage1 = object
    var s1 = withStage1["stage1"] as! [String: Any]
    s1["sha256"] = RecoveryDigest.sha256(stage1)
    withStage1["stage1"] = s1
    let staged = signed(withStage1)
    let stubInfo = try JSONSerialization.data(withJSONObject: [
      "vgid": request.group, "system_version": ["ProductVersion": "13.5"],
    ])
    let good = StubUpgradeFacts(
      group: request.group, chipID: 0x8112, deviceClass: "j413ap",
      espPartitionUUID: request.espPartitionUUID.uppercased(), espRequest: staged,
      stubInfo: stubInfo, espFreeBytes: 300 << 20, systemFirmware: "iBoot-13822.61.2",
      stage1: stage1, containerFreeBytes: 1_450_000_000, recoveryImageBytes: 810_000_000,
      recoveryImageReleasable: true, systemVersionVisible: false, systemVersionHidden: true,
      launchedByMarker: true)
    expect((try? StubUpgradeCheck.verify(config: staged, facts: good)) != nil, "good facts pass")
    func refusal(
      _ what: String, _ want: StubUpgradeCheck.Refusal, config: Data = staged,
      _ change: (inout StubUpgradeFacts) -> Void
    ) {
      var facts = good
      change(&facts)
      do {
        _ = try StubUpgradeCheck.verify(config: config, facts: facts)
        expect(false, "\(what): passed")
      } catch {
        expect(error as? StubUpgradeCheck.Refusal == want, "\(what): \(error), want \(want)")
        expect(
          (error as? LocalizedError)?.errorDescription?.contains("Nothing was changed") == true,
          "\(what): says nothing changed")
      }
    }
    refusal("not launched", .notLaunched) { $0.launchedByMarker = false }
    refusal("no request", .notStaged, config: Data("{}".utf8)) { _ in }
    refusal("another group", .otherVolume) { $0.group = "7A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8" }
    refusal("another chip", .otherMac) { $0.chipID = 0x8122 }
    refusal("no chip", .otherMac) { $0.chipID = nil }
    refusal("another board", .otherMac) { $0.deviceClass = "j415ap" }
    refusal("another ESP", .otherPartition) {
      $0.espPartitionUUID = "2b2c3d4e-5f60-4172-8394-a5b6c7d8e9f0"
    }
    refusal("no ESP", .otherPartition) { $0.espPartitionUUID = nil }
    refusal("no ESP request", .requestDiffers) { $0.espRequest = nil }
    refusal("another plan on the ESP", .requestDiffers) { $0.espRequest = config }
    refusal("no stub_info.json", .noStubInfo) { $0.stubInfo = nil }
    refusal("stub_info.json of another group", .noStubInfo) {
      $0.stubInfo = try! JSONSerialization.data(withJSONObject: [
        "vgid": "7A1E2B3C-4D5E-4F60-8172-8394A5B6C7D8"
      ])
    }
    refusal(
      "firmware below the floor", .firmwareFloor(have: "iBoot-11881.1.1", need: "iBoot-13822.41.1")
    ) { $0.systemFirmware = "iBoot-11881.1.1" }
    refusal("no firmware version", .firmwareFloor(have: "unknown", need: "iBoot-13822.41.1")) {
      $0.systemFirmware = nil
    }
    refusal("another Stage 1", .stage1Changed) { $0.stage1 = Data("other".utf8) }
    refusal("both version files", .versionMetadata) { $0.systemVersionVisible = true }
    refusal("no version file", .versionMetadata) { $0.systemVersionHidden = false }
    refusal("a full ESP", .partitionFull) { $0.espFreeBytes = 99 << 20 }

    // The installer's version rule.
    for (a, b, want) in [
      ("iBoot-13822.41.1", "iBoot-13822.41.1", true),
      ("iBoot-13822.61.2", "iBoot-13822.41.1", true),
      ("iBoot-11881.1.1", "iBoot-13822.41.1", false), ("27.2", "26.0", true),
      ("13.5", "26.0", false),
      ("26.0", "26.0.1", false), ("26.0.1", "26.0", true), ("26.1 beta 2", "26.1", false),
      ("26.1 beta 2", "26.0", true),
    ] {
      expect(
        (try? StubUpgradeCheck.versionAtLeast(a, b)) == want, "\(a) at least \(b): want \(want)")
    }
    expect((try? StubUpgradeCheck.versionAtLeast("26.x", "26.1")) == nil, "mixed parts refused")

    // A release's unfilled Stage 1 filled for this ESP reads back as it.
    let magic = Data("AURORA-S1-CFG01\0".utf8)
    let unfilled =
      Data(repeating: 0x5a, count: 64) + magic + Data([1, 0, 0, 0])
      + Data(repeating: 0, count: 240) + Data(repeating: 0x5b, count: 64)
    let filled = try Stage1Configuration.filled(
      unfilled, espUUID: request.espPartitionUUID.uppercased(), stage2Path: "m1n1/boot.bin")
    let read = try Stage1Configuration.read(filled)
    expect(read.espUUID == request.espPartitionUUID && read.stage2Path == "m1n1/boot.bin", "filled")
    expect(filled.count == unfilled.count && filled.prefix(80) == unfilled.prefix(80), "in place")
    expect(filled.suffix(64) == unfilled.suffix(64), "the rest kept")
    let again = try Stage1Configuration.filled(
      filled, espUUID: request.espPartitionUUID, stage2Path: "m1n1/boot.bin")
    expect(again == filled, "filling again changes nothing")
    for (what, image) in [
      ("no block", Data(repeating: 0, count: 400)), ("two blocks", unfilled + unfilled),
      (
        "version 2",
        Data(repeating: 0x5a, count: 64) + magic + Data([2, 0, 0, 0])
          + Data(repeating: 0, count: 300)
      ),
    ] {
      expect(
        (try? Stage1Configuration.filled(
          image, espUUID: request.espPartitionUUID, stage2Path: "m1n1/boot.bin")) == nil,
        "\(what) refused")
    }
    expect(
      (try? Stage1Configuration.filled(unfilled, espUUID: "x", stage2Path: "m1n1/boot.bin")) == nil,
      "a bad ESP UUID refused")

    // A stub without a bootstrap record: its own owner, else the one copied
    // administrator who owns another macOS volume group.
    let alice = "11111111-2222-4333-8444-555555555555"
    let bob = "21111111-2222-4333-8444-555555555555"
    let admins: [String: Any] = ["alice": ["GeneratedUID": alice], "bob": ["GeneratedUID": bob]]
    func users(_ ids: [String]) -> [String: Any] {
      ["Users": ids.map { ["APFSCryptoUserUUID": $0, "VolumeOwner": true] }]
    }
    let none = users([])
    expect(
      (try? RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: none, sources: [users([alice])]))?
        .username == "alice", "the source owner")
    expect(
      (try? RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: users([bob]), sources: [users([alice])]))?
        .username == "bob", "the stub's own owner first")
    expect(
      (try? RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: none, sources: [users([alice]), users([alice])]))?.username
        == "alice", "the same owner of two groups")
    do {
      _ = try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: none, sources: [users([alice]), users([bob])])
      expect(false, "two owners resolved")
    } catch RecoveryOwnerError.ambiguous {
    } catch { expect(false, "two owners: \(error)") }
    do {
      _ = try RecoveryOwnerResolver.resolve(
        admins: admins, targetUsers: none,
        sources: [users(["31111111-2222-4333-8444-555555555555"])])
      expect(false, "a stranger resolved")
    } catch RecoveryOwnerError.noOwner {
    } catch { expect(false, "a stranger: \(error)") }

    if failures > 0 {
      print("StubUpgradeRequest: \(failures) failures")
      exit(1)
    }
    print("StubUpgradeRequest: request, checks, versions, Stage 1 fill and owners OK")
  }
}
