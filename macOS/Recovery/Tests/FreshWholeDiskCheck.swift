import Foundation

// A fresh whole-disk installation, planned and replayed on the layout of a
// 251 GB M2 Mac as Apple ships it: iSC, one macOS, System Recovery (offsets
// and sizes from the J473's GPT, 4096-byte sectors).
@main struct Check {
  static let sector: UInt64 = 4096
  static let isc = WholeDiskPartition(
    identifier: "disk0s1", uuid: "A4F8108B-5947-4704-8443-270DA7A387F6", type: "Apple_APFS_ISC",
    offset: 6 * sector, size: 128_000 * sector)
  static let macOSPart = WholeDiskPartition(
    identifier: "disk0s2", uuid: "BC0BE725-522A-482A-A65E-2920C3DCF8D8", type: "Apple_APFS",
    offset: 128_006 * sector, size: 59_840_624 * sector)
  static let sfr = WholeDiskPartition(
    identifier: "disk0s3", uuid: "BDEC1911-82EA-4D1E-BD69-BE51B7920694",
    type: "Apple_APFS_Recovery", offset: 59_968_630 * sector, size: 1_310_709 * sector)
  static let macGroup = "1C4CD44A-0C57-46F1-A834-58808BFF3A68"
  static func vol(_ uuid: String, _ name: String, _ role: String, _ group: String? = nil)
    -> WholeDiskVolume
  {
    WholeDiskVolume(uuid: uuid, name: name, roles: [role], group: group)
  }
  static let macOS = WholeDiskContainer(
    uuid: "22222222-2222-4222-8222-222222222222", reference: "disk3", storeUUID: macOSPart.uuid,
    volumes: [
      vol("289201F6-2691-4B71-8CB2-42C376C6986D", "Macintosh HD", "System", macGroup),
      vol(macGroup, "Data", "Data", macGroup),
      vol("B383A990-6E71-458A-880B-A18AA4CBD078", "Preboot", "Preboot"),
      vol("515CA90E-4695-49FD-A254-4EDA5A16FD34", "Recovery", "Recovery"),
      vol("F19BDFD6-EA36-4F24-A96E-083159C0319B", "Update", "Update"),
      vol("95FEA450-5D7B-480E-B582-09BDC69F8122", "VM", "VM"),
    ])
  static let iscContainer = WholeDiskContainer(
    uuid: "11111111-1111-4111-8111-111111111111", reference: "disk1", storeUUID: isc.uuid,
    volumes: [vol("08393B35-B9B9-4FC3-94C6-3D41B0F3F82C", "iSCPreboot", "Preboot")])
  static let sfrContainer = WholeDiskContainer(
    uuid: "44444444-4444-4444-8444-444444444444", reference: "disk2", storeUUID: sfr.uuid,
    volumes: [vol("BEDC4AAE-2A98-4FD1-A663-55A8C9DD4321", "Recovery", "Recovery")])
  static let diskSize: UInt64 = 251_000_193_024
  static let request = FreshWholeDiskRequest(
    stubBytes: 5_999_951_872, espBytes: 524_288_000, bootBytes: 2_147_483_648,
    rootMinimumBytes: 34_359_738_368, label: "Aurora")

  static func layout(_ parts: [WholeDiskPartition], _ containers: [WholeDiskContainer])
    -> WholeDiskLayout
  {
    WholeDiskLayout(
      disk: "disk0", diskSize: diskSize, partitions: parts.sorted { $0.offset < $1.offset },
      containers: containers)
  }
  static var factory: WholeDiskLayout {
    layout([isc, macOSPart, sfr], [iscContainer, macOS, sfrContainer])
  }

  static var failures = 0
  static func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
      failures += 1
      print("FAIL line \(line): \(what)")
    }
  }
  static func refuses(_ what: String, line: Int = #line, _ body: () throws -> Void) {
    do {
      try body()
      check(false, "expected a refusal: \(what)", line: line)
    } catch let r as FreshWholeDiskRefusal {
      check(!r.message.isEmpty, what, line: line)
    } catch {
      check(false, "\(what): unexpected \(error)", line: line)
    }
  }

  /// What diskutil does for each step, on the model of the disk.
  static func apply(_ step: FreshWholeDiskStep, to disk: inout WholeDiskLayout, n: inout Int) {
    var parts = disk.partitions
    var containers = disk.containers
    switch step {
    case .removeMacOS:
      parts.removeAll { $0.uuid == macOSPart.uuid }
      containers.removeAll { $0.uuid == macOS.uuid }
    case .create(let role, let predecessor):
      let pred = parts.first { $0.identifier == predecessor }!
      let args = FreshWholeDisk.createArguments(
        role, predecessor: predecessor, plan: try! FreshWholeDisk.plan(factory, request: request),
        request: request)
      let size = UInt64(args.last!)!
      n += 1
      let uuid = String(format: "00000000-0000-4000-8000-%012d", n)
      parts.append(
        WholeDiskPartition(
          identifier: "disk0s\(n + 3)", uuid: uuid, type: role.type, offset: pred.end, size: size))
      if role == .stub {
        containers.append(
          WholeDiskContainer(
            uuid: "55555555-5555-4555-8555-555555555555", reference: "disk4", storeUUID: uuid,
            volumes: [
              vol("A4514508-89A3-43F3-8DF8-0F6950D2FA3E", "Aurora", "System"),
              vol("0E3F2FC4-18DE-42ED-955F-2CF407EB27E2", "Aurora - Data", "Data"),
            ]))
      }
    case .laidOut:
      break
    }
    disk = layout(parts, containers)
  }

  static func main() throws {
    let plan = try FreshWholeDisk.plan(factory, request: request)
    check(plan.macOSPartition == macOSPart && plan.macOS == macOS, "macOS is the one to delete")
    check(plan.extentOffset == isc.end && plan.extentSize == sfr.offset - isc.end, "extent")
    check(plan.rows.map(\.role) == [.stub, .esp, .boot, .root], "row order")
    check(plan.rows[0].offset == isc.end, "stub right after iSC")
    for (a, b) in zip(plan.rows, plan.rows.dropFirst()) {
      check(a.end == b.offset, "\(a.role) touches \(b.role)")
    }
    check(plan.rows.last!.end == sfr.offset, "root ends at System Recovery")
    check(plan.rows.allSatisfy { $0.offset % 4096 == 0 && $0.size % 4096 == 0 }, "4K blocks")
    check(
      plan.rows.last!.size == sfr.offset - isc.end - 5_999_951_872 - 524_288_000 - 2_147_483_648,
      "root takes the rest")
    check(
      FreshWholeDisk.createArguments(.stub, predecessor: "disk0s1", plan: plan, request: request)
        == ["addPartition", "disk0s1", "apfs", "Aurora", "5999951872"], "stub arguments")
    check(
      FreshWholeDisk.createArguments(.esp, predecessor: "disk0s4", plan: plan, request: request)
        == ["addPartition", "disk0s4", "%EFI%", "%noformat%", "524288000"], "ESP arguments")
    check(
      FreshWholeDisk.createArguments(.root, predecessor: "disk0s6", plan: plan, request: request)
        == ["addPartition", "disk0s6", "%Linux%", "%noformat%", String(plan.rows[3].size)],
      "root arguments")
    let text = FreshWholeDisk.describe(plan)
    check(text.contains("WILL BE DELETED") && text.contains("Macintosh HD"), "describe deletion")
    check(text.contains("Apple System Recovery") && text.contains("Linux root"), "describe rest")
    check(FreshWholeDisk.phrase == "remove macos and all its data", "phrase")

    // Replay every step, re-planning from the disk at each one as a resumed
    // installation without its journal would, and check each lands as planned.
    var disk = factory
    var n = 0
    var steps = [FreshWholeDiskStep]()
    while true {
      let step = try FreshWholeDisk.next(plan, now: disk)
      steps.append(step)
      if step == .laidOut { break }
      if step != .removeMacOS {
        let resumed = try FreshWholeDisk.plan(disk, request: request)
        check(resumed.rows == plan.rows && resumed.macOS == nil, "resumed plan at \(step)")
        check(try FreshWholeDisk.next(resumed, now: disk) == step, "resumed next at \(step)")
      }
      apply(step, to: &disk, n: &n)
      check(steps.count < 10, "terminates")
    }
    check(
      steps == [
        .removeMacOS, .create(.stub, predecessor: "disk0s1"), .create(.esp, predecessor: "disk0s4"),
        .create(.boot, predecessor: "disk0s5"), .create(.root, predecessor: "disk0s6"), .laidOut,
      ], "steps \(steps)")
    let parts = try FreshWholeDisk.verifyLaidOut(plan, after: disk)
    check(parts.count == 4 && parts[.root]!.end == sfr.offset, "verified layout")
    check(
      disk.partitions.map(\.type) == [
        "Apple_APFS_ISC", "Apple_APFS", "EFI", "Linux Filesystem", "Linux Filesystem",
        "Apple_APFS_Recovery",
      ], "final order iSC/stub/ESP/boot/root/SFR")
    check(disk.partitions.first == isc && disk.partitions.last == sfr, "Apple ends untouched")
    let record = FreshWholeDisk.linuxRecord(plan, parts: parts, at: Date(timeIntervalSince1970: 0))
    check(record["layout"] as? String == "fresh-whole-disk", "record layout")
    check(record["rootPartitionUUID"] as? String == parts[.root]!.uuid, "record root")
    check(record["removedPartitionUUID"] as? String == macOSPart.uuid, "record removed")
    check(
      (try? JSONSerialization.data(withJSONObject: record)) != nil, "record is JSON")

    // A disk with nothing between Apple's containers installs directly.
    let empty = layout([isc, sfr], [iscContainer, sfrContainer])
    let direct = try FreshWholeDisk.plan(empty, request: request)
    check(direct.macOS == nil && direct.rows == plan.rows, "empty disk plan")
    check(
      try FreshWholeDisk.next(direct, now: empty) == .create(.stub, predecessor: "disk0s1"),
      "empty disk starts with the stub")
    // Laid out: planning again accepts it and has nothing left to do.
    check(try FreshWholeDisk.next(FreshWholeDisk.plan(disk, request: request), now: disk) == .laidOut,
      "replan a finished disk")

    // The reviewed plan must still hold before deletion.
    try FreshWholeDisk.requireUnchanged(plan, now: factory, request: request)
    refuses("changed before deletion") {
      var grown = macOSPart
      grown = WholeDiskPartition(
        identifier: grown.identifier, uuid: grown.uuid, type: grown.type, offset: grown.offset,
        size: grown.size - 4096)
      try FreshWholeDisk.requireUnchanged(
        plan, now: layout([isc, grown, sfr], [iscContainer, macOS, sfrContainer]),
        request: request)
    }

    // Refusals on the first reading.
    refuses("Aurora already installed") {
      let stub = WholeDiskPartition(
        identifier: "disk0s3", uuid: "19894DF2-B017-431A-90EB-F9D177CF75AC", type: "Apple_APFS",
        offset: macOSPart.end - 1_464_844 * sector, size: 610_304 * sector)
      let shrunk = WholeDiskPartition(
        identifier: "disk0s2", uuid: macOSPart.uuid, type: "Apple_APFS", offset: macOSPart.offset,
        size: macOSPart.size - 1_464_844 * sector)
      _ = try FreshWholeDisk.plan(
        layout([isc, shrunk, stub, sfr], [iscContainer, macOS, sfrContainer]), request: request)
    }
    refuses("a non-macOS APFS container") {
      let other = WholeDiskContainer(
        uuid: macOS.uuid, reference: "disk3", storeUUID: macOSPart.uuid,
        volumes: [vol("289201F6-2691-4B71-8CB2-42C376C6986D", "Stuff", "Data")])
      _ = try FreshWholeDisk.plan(
        layout([isc, macOSPart, sfr], [iscContainer, other, sfrContainer]), request: request)
    }
    refuses("macOS with an extra volume") {
      let extra = WholeDiskContainer(
        uuid: macOS.uuid, reference: "disk3", storeUUID: macOSPart.uuid,
        volumes: macOS.volumes + [vol("8F0F0C51-6A2C-4D05-9A2B-1F5D2E3C4B5A", "Photos", "")])
      _ = try FreshWholeDisk.plan(
        layout([isc, macOSPart, sfr], [iscContainer, extra, sfrContainer]), request: request)
    }
    refuses("container not listed") {
      _ = try FreshWholeDisk.plan(
        layout([isc, macOSPart, sfr], [iscContainer, sfrContainer]), request: request)
    }
    refuses("a Linux partition beside macOS") {
      let linux = WholeDiskPartition(
        identifier: "disk0s4", uuid: "36D0EBB8-8585-473E-8ACF-0E63AA658687",
        type: "Linux Filesystem", offset: macOSPart.end - 262_144 * sector,
        size: 262_144 * sector)
      let shrunk = WholeDiskPartition(
        identifier: "disk0s2", uuid: macOSPart.uuid, type: "Apple_APFS", offset: macOSPart.offset,
        size: macOSPart.size - 262_144 * sector)
      _ = try FreshWholeDisk.plan(
        layout([isc, shrunk, linux, sfr], [iscContainer, macOS, sfrContainer]), request: request)
    }
    refuses("no iSC first") {
      _ = try FreshWholeDisk.plan(layout([macOSPart, sfr], [macOS, sfrContainer]), request: request)
    }
    refuses("no System Recovery last") {
      _ = try FreshWholeDisk.plan(layout([isc, macOSPart], [iscContainer, macOS]), request: request)
    }
    refuses("overlap") {
      let wide = WholeDiskPartition(
        identifier: "disk0s2", uuid: macOSPart.uuid, type: "Apple_APFS", offset: macOSPart.offset,
        size: macOSPart.size + sector)
      _ = try FreshWholeDisk.plan(
        layout([isc, wide, sfr], [iscContainer, macOS, sfrContainer]), request: request)
    }
    refuses("disk too small") {
      let big = FreshWholeDiskRequest(
        stubBytes: request.stubBytes, espBytes: request.espBytes, bootBytes: request.bootBytes,
        rootMinimumBytes: 300_000_000_000 / (1 << 20) * (1 << 20), label: "Aurora")
      _ = try FreshWholeDisk.plan(factory, request: big)
    }
    refuses("size not a MiB multiple") {
      let odd = FreshWholeDiskRequest(
        stubBytes: request.stubBytes + 4096, espBytes: request.espBytes,
        bootBytes: request.bootBytes, rootMinimumBytes: request.rootMinimumBytes, label: "Aurora")
      _ = try FreshWholeDisk.plan(factory, request: odd)
    }

    // Refusals while resuming.
    var afterStub = factory
    var m = 0
    apply(.removeMacOS, to: &afterStub, n: &m)
    apply(.create(.stub, predecessor: "disk0s1"), to: &afterStub, n: &m)
    check(
      try FreshWholeDisk.next(plan, now: afterStub) == .create(.esp, predecessor: "disk0s4"),
      "after the stub comes the ESP")
    refuses("a partition not where planned") {
      var parts = afterStub.partitions
      let i = parts.firstIndex { $0.type == "Apple_APFS" && $0.uuid != isc.uuid }!
      let p = parts[i]
      parts[i] = WholeDiskPartition(
        identifier: p.identifier, uuid: p.uuid, type: p.type, offset: p.offset,
        size: p.size + 1 << 20)
      _ = try FreshWholeDisk.next(plan, now: layout(parts, afterStub.containers))
    }
    refuses("System Recovery changed") {
      let moved = WholeDiskPartition(
        identifier: sfr.identifier, uuid: "BDEC1911-82EA-4D1E-BD69-BE51B7920695", type: sfr.type,
        offset: sfr.offset, size: sfr.size)
      _ = try FreshWholeDisk.next(
        plan, now: layout(afterStub.partitions.dropLast() + [moved], afterStub.containers))
    }
    refuses("macOS half there") {
      _ = try FreshWholeDisk.next(plan, now: layout([isc, sfr], [iscContainer, macOS, sfrContainer]))
    }
    refuses("a macOS where the stub goes") {
      let fake = WholeDiskContainer(
        uuid: macOS.uuid, reference: "disk4", storeUUID: afterStub.partitions[1].uuid,
        volumes: macOS.volumes)
      _ = try FreshWholeDisk.next(
        plan, now: layout(afterStub.partitions, [iscContainer, sfrContainer, fake]))
    }
    refuses("another disk") {
      let other = WholeDiskLayout(
        disk: "disk1", diskSize: diskSize, partitions: factory.partitions,
        containers: factory.containers)
      _ = try FreshWholeDisk.next(plan, now: other)
    }
    refuses("not laid out yet") { _ = try FreshWholeDisk.verifyLaidOut(plan, after: afterStub) }

    if failures > 0 {
      print("fresh-whole-disk: \(failures) failure(s)")
      exit(1)
    }
    print("fresh-whole-disk: all checks passed (\(steps.count) steps)")
  }
}
