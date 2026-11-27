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

// StubUpgradeGrow with a stand-in for diskutil (a runner that grows the
// layout, or doesn't) on aurora-upgrade's own in-place-grow plan
// (Fixtures/StubUpgrade/grow.json): the container grows once, only when the
// EFI partition is at its new place and its old range right after the
// container is free and large enough, to the planned size, and the journal
// records it so a rerun skips it; and StubUpgradeRecords: stub_info.json,
// the EFI partition's journal ("upgraded", once) and the Recovery baseline
// `aura recover` compares.
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
  static let fm = FileManager.default

  static func main() throws {
    umask(0o077)
    let request = try StubUpgradeRequest.decode(
      Data(contentsOf: fixtures.appendingPathComponent("grow.json")))
    let inPlace = try StubUpgradeRequest.decode(
      Data(contentsOf: fixtures.appendingPathComponent("upgrade-config.json")))
    let move = request.espMove!
    let want = request.growContainerTo!
    let store = "disk0s3"
    let container = 2_499_805_184
    let containerStart = move.oldStart - container
    let mib = 1 << 20
    // The J413's order: iBootSystemContainer, macOS, the moved ESP, the stub,
    // the ESP's old place (free), then Linux's root.
    func layout(
      containerSize: Int = container, esp: Int? = nil, extra: [StubUpgradeGrow.Partition] = [],
      root: Int? = nil, disk: Int = 1 << 40
    ) -> StubUpgradeGrow.Layout {
      StubUpgradeGrow.Layout(
        partitions: [
          .init(bsdName: "disk0s1", uuid: UUID().uuidString, base: 24_576, size: 500 * mib),
          .init(bsdName: "disk0s2", uuid: UUID().uuidString, base: 501 * mib, size: 400 << 30),
          .init(
            bsdName: "disk0s4", uuid: request.espPartitionUUID.uppercased(),
            base: esp ?? move.newStart, size: move.size),
          .init(bsdName: store, uuid: UUID().uuidString, base: containerStart, size: containerSize),
          .init(
            bsdName: "disk0s5", uuid: UUID().uuidString,
            base: root ?? (move.oldStart + move.size + 2 * mib), size: 100 << 30),
        ] + extra, diskSize: disk)
    }
    let base = fm.temporaryDirectory.appendingPathComponent("stub-grow-" + UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    /// One run: the disk as `start`, a runner that turns it into `after`.
    func grow(
      _ what: String, _ start: StubUpgradeGrow.Layout, after: StubUpgradeGrow.Layout? = nil,
      request: StubUpgradeRequest = request, want refusal: StubUpgradeGrow.Refusal? = nil,
      resizes wanted: Int, grown: Bool
    ) {
      let url = base.appendingPathComponent(UUID().uuidString + ".json")
      var disk = start
      var resizes = 0
      do {
        try StubUpgradeGrow.run(
          request: request, store: store, journal: url, layout: { disk },
          resize: {
            resizes += 1
            if let after { disk = after }
          })
        expect(refusal == nil, "\(what): not refused")
      } catch {
        expect(
          error as? StubUpgradeGrow.Refusal == refusal,
          "\(what): \(error), want \(String(describing: refusal))")
      }
      expect(resizes == wanted, "\(what): \(resizes) resizes, want \(wanted)")
      let saved = (try? RestoreImageStubUpgrade.Journal.load(url)) ?? nil
      expect((saved?.containerGrown == true) == grown, "\(what): recorded grown \(grown)")
      // A refusal leaves no journal behind.
      expect(grown || saved == nil, "\(what): a refusal left a journal")
      // Run again: a recorded growth is never repeated.
      if grown {
        var more = 0
        try? StubUpgradeGrow.run(
          request: request, store: store, journal: url, layout: { disk },
          resize: { more += 1 })
        expect(more == 0, "\(what): grown again")
      }
    }
    let grownLayout = layout(containerSize: want - 4096)
    grow("the planned layout", layout(), after: grownLayout, resizes: 1, grown: true)
    grow(
      "more free space after the old place", layout(root: move.oldStart + move.size + (8 << 30)),
      after: layout(containerSize: want + (8 << 30), root: move.oldStart + move.size + (8 << 30)),
      resizes: 1, grown: true)
    grow("grown before the journal said so", grownLayout, resizes: 0, grown: true)
    grow(
      "diskutil that grew nothing", layout(), after: layout(),
      want: .didNotGrow(size: container, want: want), resizes: 1, grown: false)
    grow(
      "diskutil that grew too little", layout(), after: layout(containerSize: want - 2 * mib),
      want: .didNotGrow(size: want - 2 * mib, want: want), resizes: 1, grown: false)
    grow(
      "the ESP still in its old place", layout(esp: move.oldStart), want: .espNotMoved, resizes: 0,
      grown: false)
    grow(
      "a partition in the old place",
      layout(extra: [
        .init(bsdName: "disk0s6", uuid: UUID().uuidString, base: move.oldStart + mib, size: mib)
      ]), want: .notFree, resizes: 0, grown: false)
    grow(
      "a container that doesn't end at the old place",
      layout(containerSize: container - 2 * mib), want: .notFree, resizes: 0, grown: false)
    grow(
      "Linux's root right after the container", layout(root: move.oldStart),
      want: .notFree, resizes: 0, grown: false)
    grow(
      "the disk ending inside the old place", layout(root: 1 << 41, disk: move.oldStart + mib),
      want: .smallerThanExpected, resizes: 0, grown: false)
    grow(
      "no container", StubUpgradeGrow.Layout(partitions: [], diskSize: 1 << 40),
      want: .espNotMoved, resizes: 0, grown: false)
    grow("an in-place plan", layout(), request: inPlace, resizes: 0, grown: false)

    // stub_info.json: the new firmware, everything else kept.
    let planImage = here.appendingPathComponent("Fixtures/RestoreImageStubPlan/ok.zip")
    let planExpected =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: here.appendingPathComponent("Fixtures/RestoreImageStubPlan/expected.json")))
      as! [String: Any]
    let bytes = [UInt8](try Data(contentsOf: planImage))
    let read: RestoreImageDirectory.Read = { Data(bytes[$0..<($0 + $1)]) }
    let directory = try RestoreImageDirectory.read(archiveSize: bytes.count, read: read)
    let manifest = try directory.contents(
      directory.entries.first { $0.name == "BuildManifest.plist" }!, read: read)
    let plan = try RestoreImageStubPlan(
      directory: directory, read: read, productVersion: planExpected["version"] as! String,
      deviceClass: planExpected["device_class"] as! String,
      boardID: UInt64(planExpected["board"] as! Int), chipID: UInt64(planExpected["chip"] as! Int),
      pin: .init(
        sourceBytes: bytes.count, manifestSHA256: RecoveryDigest.sha256(manifest),
        build: planExpected["build"] as! String),
      sha256: RecoveryDigest.sha256)
    let oldInfo = try JSONSerialization.data(withJSONObject: [
      "vgid": request.group, "admin_users": ["alice": ["uid": "1"]],
      "system_version": ["ProductVersion": "13.5"], "manifest_info": ["build_number": "20G75"],
    ])
    let info =
      try JSONSerialization.jsonObject(
        with: StubUpgradeRecords.stubInfo(oldInfo, plan: plan, group: request.group))
      as! [String: Any]
    let new = try JSONSerialization.jsonObject(with: plan.stubInfo) as! [String: Any]
    expect(
      (info["manifest_info"] as? [String: Any])?["build_number"] as? String
        == planExpected["build"] as? String
        && (info["system_version"] as? [String: Any])?["ProductVersion"] as? String
          == (new["system_version"] as? [String: Any])?["ProductVersion"] as? String,
      "stub_info.json names the new firmware")
    expect(
      info["vgid"] as? String == request.group && info["admin_users"] != nil,
      "stub_info.json keeps the rest")

    // The EFI partition's journal: "upgraded", the step once.
    let linux = try JSONSerialization.data(withJSONObject: [
      "schema": 1, "plan_sha256": request.planSHA256, "state": "staged",
      "steps": [["kind": "staged", "time": 1]],
    ])
    let once = try StubUpgradeRecords.espJournal(linux, request: request, time: 2)
    let twice = try StubUpgradeRecords.espJournal(once, request: request, time: 3)
    for (what, data) in [("first", once), ("again", twice)] {
      let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let steps = value["steps"] as! [[String: Any]]
      expect(value["state"] as? String == "upgraded", "\(what): state upgraded")
      expect(
        steps.count == 2 && steps[0]["kind"] as? String == "staged"
          && steps[1]["kind"] as? String == "recovery-upgraded"
          && steps[1]["build"] as? String == request.target.build,
        "\(what): steps \(steps)")
    }
    let started =
      try JSONSerialization.jsonObject(
        with: StubUpgradeRecords.espJournal(nil, request: request, time: 2)) as! [String: Any]
    expect(
      started["state"] as? String == "upgraded" && (started["steps"] as? [Any])?.count == 1
        && started["schema"] as? Int == 1, "a missing journal is started")
    expect(
      (try? StubUpgradeRecords.espJournal(Data("[".utf8), request: request, time: 2)) == nil,
      "an unreadable journal is refused")
    // A refused bless: the EFI journal says so, then "upgraded" once it is done.
    let waiting =
      try JSONSerialization.jsonObject(
        with: StubUpgradeRecords.espJournal(
          linux, request: request, time: 2, state: RestoreImageStubUpgrade.needsMacOSBlessState))
      as! [String: Any]
    expect(
      waiting["state"] as? String == "needs-macos-bless"
        && (waiting["steps"] as? [[String: Any]])?.last?["kind"] as? String
          == "recovery-needs-macos-bless",
      "the EFI journal waits for macOS")
    let done =
      try JSONSerialization.jsonObject(
        with: StubUpgradeRecords.espJournal(
          JSONSerialization.data(withJSONObject: waiting), request: request, time: 3))
      as! [String: Any]
    expect(
      done["state"] as? String == "upgraded" && (done["steps"] as? [Any])?.count == 3,
      "then upgraded")

    // The Recovery baseline: the new Stage 1 and its manifest entry; the rest kept.
    let payloads = base.appendingPathComponent("AuraPayloads")
    try fm.createDirectory(
      at: payloads.appendingPathComponent("macho"), withIntermediateDirectories: true)
    let oldStage1 = Data("old stage 1".utf8)
    try oldStage1.write(to: payloads.appendingPathComponent("macho/aura-boot.macho"))
    let entries: [String: Any] = [
      "macho/aura-boot.macho": [
        "bytes": oldStage1.count, "sha256": RecoveryDigest.sha256(oldStage1), "mode": "macho",
      ],
      "raw/boot.bin": ["bytes": 3, "sha256": String(repeating: "a", count: 64)],
    ]
    try JSONSerialization.data(withJSONObject: [
      "schema": 2, "defaultMode": "macho-standard", "files": entries,
    ]).write(to: payloads.appendingPathComponent("manifest.json"))
    let newStage1 = Data("new stage 1, filled".utf8)
    try StubUpgradeRecords.updateBaseline(
      payloads: payloads, stage1: newStage1, path: "macho/aura-boot.macho")
    let after =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: payloads.appendingPathComponent("manifest.json")))
      as! [String: Any]
    let files = after["files"] as! [String: [String: Any]]
    expect(
      try Data(contentsOf: payloads.appendingPathComponent("macho/aura-boot.macho")) == newStage1,
      "the baseline holds the new Stage 1")
    expect(
      files["macho/aura-boot.macho"]?["sha256"] as? String == RecoveryDigest.sha256(newStage1)
        && files["macho/aura-boot.macho"]?["bytes"] as? Int == newStage1.count
        && files["macho/aura-boot.macho"]?["mode"] as? String == "macho",
      "its manifest entry names it")
    expect(
      files["raw/boot.bin"]?["bytes"] as? Int == 3
        && after["defaultMode"] as? String
          == "macho-standard"
        && after["schema"] as? Int == 2, "the rest of the manifest is kept")
    // What `aura recover` and the pending update check compare: the receipt
    // Update startup software writes for the same Stage 1.
    let receipt = Stage1Reenrollment(
      mode: .standard, stage1SHA256: RecoveryDigest.sha256(newStage1), stage2Path: "m1n1/boot.bin"
    ).receipt(
      after: ["status": "installed", "mode": "raw", "stage1SHA256": "old"],
      stage2SHA256: "s2")
    expect(
      Stage1Reenrollment.pending(
        receipt: receipt, hasPendingInstallation: false, bootMode: "macho-standard",
        stage2Path: "m1n1/boot.bin",
        manifest: [
          "defaultMode": "macho-standard",
          "modes": ["macho-standard": ["espPath": "m1n1/boot.bin"]],
          "files": files,
        ]) == nil,
      "the receipt and the baseline agree: nothing pending, recover's comparison matches")

    if failures > 0 {
      print("StubUpgradeGrow: \(failures) failures")
      exit(1)
    }
    print("StubUpgradeGrow: container growth, stub_info.json, EFI journal and baseline OK")
  }
}
