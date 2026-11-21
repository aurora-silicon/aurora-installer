import Foundation

// The layout of a 251 GB M2 MacBook Air with macOS and one Aurora
// installation, as diskutil reports it (partition offsets and sizes from the
// Mac's GPT, 4096-byte sectors).
@main struct Check {
  static let isc = "A4F8108B-5947-4704-8443-270DA7A387F6"
  static let macStore = "BC0BE725-522A-482A-A65E-2920C3DCF8D8"
  static let stubStore = "19894DF2-B017-431A-90EB-F9D177CF75AC"
  static let esp = "764B2A84-F950-4D70-A95C-281C76B935D5"
  static let boot = "ED151AF0-50AD-44BE-AB84-72279BB58BBE"
  static let root = "36D0EBB8-8585-473E-8ACF-0E63AA658687"
  static let recovery = "BDEC1911-82EA-4D1E-BD69-BE51B7920694"
  static let macGroup = "1C4CD44A-0C57-46F1-A834-58808BFF3A68"
  static let stubGroup = "0E3F2FC4-18DE-42ED-955F-2CF407EB27E2"
  static let stubSystem = "A4514508-89A3-43F3-8DF8-0F6950D2FA3E"
  static let installation = WholeDiskInstallation(
    systemUUID: stubSystem, groupUUID: stubGroup, espUUID: esp)

  static func part(_ n: Int, _ uuid: String, _ type: String, _ start: UInt64, _ sectors: UInt64)
    -> (String, [String: Any])
  {
    (
      "disk0s\(n)",
      [
        "DeviceIdentifier": "disk0s\(n)", "ParentWholeDisk": "disk0", "DiskUUID": uuid,
        "Content": type, "PartitionMapPartitionOffset": start * 4096, "Size": sectors * 4096,
      ]
    )
  }
  static var basePartitions: [(String, [String: Any])] {
    [
      part(1, isc, "Apple_APFS_ISC", 6, 128000),
      part(2, macStore, "Apple_APFS", 128006, 43_972_388),
      part(3, stubStore, "Apple_APFS", 44_100_394, 610_304),
      part(4, esp, "EFI", 44_710_698, 128000),
      part(5, boot, "Linux Filesystem", 44_838_698, 262144),
      part(6, root, "Linux Filesystem", 45_100_842, 14_867_712),
      part(7, recovery, "Apple_APFS_Recovery", 59_968_630, 1_310_709),
    ]
  }
  static func vol(_ uuid: String, _ name: String, _ role: String) -> [String: Any] {
    ["APFSVolumeUUID": uuid, "Name": name, "Roles": [role], "DeviceIdentifier": "x"]
  }
  static func container(_ n: Int, _ uuid: String, _ store: String, _ vols: [[String: Any]])
    -> [String: Any]
  {
    [
      "APFSContainerUUID": uuid, "ContainerReference": "disk\(n)",
      "PhysicalStores": [["DeviceIdentifier": store]], "Volumes": vols,
    ]
  }
  static let macSystem = "289201F6-2691-4B71-8CB2-42C376C6986D"
  static var macVolumes: [[String: Any]] {
    [
      vol(macSystem, "Macintosh HD", "System"), vol(macGroup, "Data", "Data"),
      vol("B383A990-6E71-458A-880B-A18AA4CBD078", "Preboot", "Preboot"),
      vol("515CA90E-4695-49FD-A254-4EDA5A16FD34", "Recovery", "Recovery"),
      vol("F19BDFD6-EA36-4F24-A96E-083159C0319B", "Update", "Update"),
      vol("95FEA450-5D7B-480E-B582-09BDC69F8122", "VM", "VM"),
    ]
  }
  static var stubVolumes: [[String: Any]] {
    [
      vol(stubSystem, "Aurora", "System"), vol(stubGroup, "Aurora - Data", "Data"),
      vol("E82474F6-4007-4A8B-A931-6E938C151538", "Preboot", "Preboot"),
      vol("51D0B9F1-98AA-422D-82A8-012CD1EBC306", "Recovery", "Recovery"),
    ]
  }
  static func layout(
    partitions: [(String, [String: Any])] = basePartitions,
    containers: [[String: Any]]? = nil, groups: [[String: Any]]? = nil
  ) throws -> WholeDiskLayout {
    let list: [String: Any] = [
      "AllDisksAndPartitions": [
        [
          "DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme",
          "Partitions": partitions.map { ["DeviceIdentifier": $0.0] },
        ]
      ]
    ]
    let apfs: [String: Any] = [
      "Containers": containers ?? [
        container(
          1, "11111111-1111-4111-8111-111111111111", "disk0s1",
          [
            vol("08393B35-B9B9-4FC3-94C6-3D41B0F3F82C", "iSCPreboot", "Preboot"),
            vol("C3AB3355-5679-48DD-BE00-7A5B228D7CEE", "xART", "xART"),
            vol("6039D97A-18CD-4FDA-B6EA-C02650052F4D", "Hardware", "Hardware"),
          ]),
        container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", macVolumes),
        container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
        container(
          2, "44444444-4444-4444-8444-444444444444", "disk0s7",
          [
            vol("BEDC4AAE-2A98-4FD1-A663-55A8C9DD4321", "Recovery", "Recovery")
          ]),
        // An external drive's container is ignored.
        container(9, "55555555-5555-4555-8555-555555555555", "disk8s2", macVolumes),
      ]
    ]
    let vg: [String: Any] = [
      "Containers": [
        [
          "VolumeGroups": groups ?? [
            [
              "APFSVolumeGroupUUID": macGroup,
              "Volumes": [["DiskUUID": macSystem], ["DiskUUID": macGroup]],
            ],
            [
              "APFSVolumeGroupUUID": stubGroup,
              "Volumes": [["DiskUUID": stubSystem], ["DiskUUID": stubGroup]],
            ],
          ]
        ]
      ]
    ]
    return try WholeDiskLayout.parse(
      disk: "disk0", diskSize: 251_000_193_024, list: list,
      infos: Dictionary(uniqueKeysWithValues: partitions), apfs: apfs, groups: vg)
  }
  static func refused(_ text: String, _ body: () throws -> Void) {
    do {
      try body()
      fatalError("expected refusal containing: \(text)")
    } catch let error as MacOSRemovalRefusal {
      precondition(error.message.contains(text), "unexpected refusal: \(error.message)")
    } catch { fatalError("unexpected error \(error)") }
  }

  static func main() throws {
    // The normal case: exactly macOS goes; six partitions stay.
    let before = try layout()
    let plan = try MacOSRemoval.plan(before, installation: installation)
    precondition(plan.partition.uuid == macStore && plan.partition.identifier == "disk0s2")
    precondition(plan.kept.map(\.uuid) == [isc, stubStore, esp, boot, root, recovery])
    precondition(plan.installationStoreUUID == stubStore && plan.otherStartupContainers.isEmpty)
    let free = MacOSRemoval.freedExtent(plan)
    precondition(free.offset == 128006 * 4096)
    precondition(free.size == 43_972_388 * 4096)
    let text = MacOSRemoval.describe(plan)
    precondition(text.contains("disk0s2") && text.contains("“Macintosh HD”"))
    precondition(
      text.contains("Aurora startup container") && text.contains("Apple System Recovery"))
    let record = MacOSRemoval.claimRecord(plan, removedAt: Date(timeIntervalSince1970: 0))
    precondition(record["removedPartitionUUID"] as? String == macStore)
    precondition(record["freeSize"] as? UInt64 == 43_972_388 * 4096)
    _ = try JSONSerialization.data(withJSONObject: record)
    try MacOSRemoval.requireUnchanged(plan, now: before, installation: installation)

    // After deletion: verified only when every kept partition is unchanged.
    let afterParts = basePartitions.filter { $0.0 != "disk0s2" }
    var afterContainers = (try layout()).containers
    afterContainers.removeAll { $0.storeUUID == macStore }
    let after = WholeDiskLayout(
      disk: "disk0", diskSize: before.diskSize,
      partitions: try layout(
        partitions: afterParts,
        containers: [
          container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes)
        ]
      ).partitions, containers: afterContainers)
    try MacOSRemoval.verifyRemoved(plan, after: after)
    refused("still on the disk") { try MacOSRemoval.verifyRemoved(plan, after: before) }
    var moved = after
    moved = WholeDiskLayout(
      disk: "disk0", diskSize: after.diskSize,
      partitions: after.partitions.map {
        $0.uuid == root
          ? WholeDiskPartition(
            identifier: $0.identifier, uuid: $0.uuid, type: $0.type, offset: $0.offset,
            size: $0.size - 4096) : $0
      }, containers: after.containers)
    refused("had to stay changed") { try MacOSRemoval.verifyRemoved(plan, after: moved) }

    // Once macOS is gone there is nothing to remove.
    refused("no macOS") {
      _ = try MacOSRemoval.plan(after, installation: installation)
    }
    // A layout that changed between review and deletion is refused.
    let changed = try layout(
      partitions: basePartitions.map {
        $0.0 == "disk0s6"
          ? part(
            6, "66666666-6666-4666-8666-666666666666", "Linux Filesystem", 45_100_842, 14_867_712)
          : $0
      })
    refused("disk changed") {
      try MacOSRemoval.requireUnchanged(plan, now: changed, installation: installation)
    }
    // Apple's first and last partitions must be where Apple puts them.
    refused("first partition") {
      _ = try MacOSRemoval.plan(
        try layout(
          partitions: basePartitions.map {
            $0.0 == "disk0s1" ? part(1, isc, "Apple_APFS", 6, 128000) : $0
          }), installation: installation)
    }
    refused("last partition") {
      _ = try MacOSRemoval.plan(
        try layout(partitions: Array(basePartitions.dropLast())), installation: installation)
    }
    // Another installation's identity isn't this one.
    refused("startup container couldn’t be found") {
      _ = try MacOSRemoval.plan(
        before,
        installation: WholeDiskInstallation(
          systemUUID: macSystem, groupUUID: stubGroup, espUUID: esp))
    }
    refused("EFI partition couldn’t be found") {
      _ = try MacOSRemoval.plan(
        before,
        installation: WholeDiskInstallation(
          systemUUID: stubSystem, groupUUID: stubGroup, espUUID: boot))
    }
    // Without group membership a System volume is not a full macOS: refused,
    // not guessed.
    refused("aren’t one volume group") {
      _ = try MacOSRemoval.plan(
        try layout(groups: [
          [
            "APFSVolumeGroupUUID": stubGroup,
            "Volumes": [["DiskUUID": stubSystem], ["DiskUUID": stubGroup]],
          ]
        ]), installation: installation)
    }
    // Two macOS installations: ambiguous.
    let second = "77777777-7777-4777-8777-777777777777"
    let twoMac =
      basePartitions.prefix(6) + [
        part(8, second, "Apple_APFS", 59_968_554, 76),
        part(7, recovery, "Apple_APFS_Recovery", 59_968_630, 1_310_709),
      ]
    refused("2 macOS installations") {
      _ = try MacOSRemoval.plan(
        try layout(
          partitions: Array(twoMac),
          containers: [
            container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", macVolumes),
            container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
            container(5, "88888888-8888-4888-8888-888888888888", "disk0s8", macVolumes),
          ]), installation: installation)
    }
    // A startup slot (System volume, no Update volume) is kept and named.
    let slotStore = "99999999-9999-4999-8999-999999999999"
    let slotSystem = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    let withSlot =
      basePartitions.prefix(6) + [
        part(8, slotStore, "Apple_APFS", 59_968_554, 76),
        part(7, recovery, "Apple_APFS_Recovery", 59_968_630, 1_310_709),
      ]
    let slotPlan = try MacOSRemoval.plan(
      try layout(
        partitions: Array(withSlot),
        containers: [
          container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", macVolumes),
          container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
          container(
            5, "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", "disk0s8",
            [
              vol(slotSystem, "Aurora 27.2", "System")
            ]),
        ]), installation: installation)
    precondition(slotPlan.partition.uuid == macStore)
    precondition(slotPlan.otherStartupContainers.map(\.storeUUID) == [slotStore])
    precondition(slotPlan.kept.contains { $0.uuid == slotStore })
    // An APFS partition diskutil can't list as a container is refused.
    refused("couldn’t be listed") {
      _ = try MacOSRemoval.plan(
        try layout(containers: [
          container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes)
        ]), installation: installation)
    }
    // Overlapping partitions and missing fields refuse.
    refused("overlap") {
      _ = try MacOSRemoval.plan(
        try layout(
          partitions: basePartitions.map {
            $0.0 == "disk0s3" ? part(3, stubStore, "Apple_APFS", 44_100_000, 610_304) : $0
          }), installation: installation)
    }
    refused("couldn’t be read") {
      var broken = basePartitions
      broken[3].1.removeValue(forKey: "PartitionMapPartitionOffset")
      _ = try layout(partitions: broken)
    }
    // deleteContainer deletes every volume in the container: a second macOS
    // or a volume someone added to macOS's container refuses, naming them.
    let withExtra: [[String: Any]] =
      macVolumes + [
        ["APFSVolumeUUID": "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", "Name": "Photos", "Roles": []]
      ]
    refused("“Photos” (no role) isn’t part of macOS") {
      _ = try MacOSRemoval.plan(
        try layout(containers: [
          container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", withExtra),
          container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
        ]), installation: installation)
    }
    let secondSystem = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    let secondData = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    let dualMac =
      macVolumes + [
        vol(secondSystem, "Macintosh HD 2", "System"), vol(secondData, "Data 2", "Data"),
      ]
    refused("2 System volumes") {
      _ = try MacOSRemoval.plan(
        try layout(
          containers: [
            container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", dualMac),
            container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
          ],
          groups: [
            [
              "APFSVolumeGroupUUID": macGroup,
              "Volumes": [["DiskUUID": macSystem], ["DiskUUID": macGroup]],
            ],
            [
              "APFSVolumeGroupUUID": secondData,
              "Volumes": [["DiskUUID": secondSystem], ["DiskUUID": secondData]],
            ],
            [
              "APFSVolumeGroupUUID": stubGroup,
              "Volumes": [["DiskUUID": stubSystem], ["DiskUUID": stubGroup]],
            ],
          ]), installation: installation)
    }
    let twoVM = macVolumes + [vol("FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", "VM 2", "VM")]
    refused("more than one VM volume") {
      _ = try MacOSRemoval.plan(
        try layout(containers: [
          container(3, "22222222-2222-4222-8222-222222222222", "disk0s2", twoVM),
          container(4, "33333333-3333-4333-8333-333333333333", "disk0s3", stubVolumes),
        ]), installation: installation)
    }
    // Find My, from nvram -x -p: the token's presence, with or without the
    // variable's GUID prefix.
    precondition(MacOSRemoval.findMyOn(nvram: ["fmm-mobileme-token-FMM": Data([1])]))
    precondition(
      MacOSRemoval.findMyOn(nvram: [
        "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14:fmm-mobileme-token-FMM": Data([1])
      ]))
    precondition(!MacOSRemoval.findMyOn(nvram: ["boot-args": "", "fmm-computer-name": "Mac"]))

    // An interrupted removal resumes only on an exact match.
    let journal = MacOSRemoval.journal(plan, removedAt: Date(timeIntervalSince1970: 0))
    let roundTrip =
      try JSONSerialization.jsonObject(
        with: try JSONSerialization.data(withJSONObject: journal)) as! [String: Any]
    let notStarted = try MacOSRemoval.resume(
      journal: roundTrip, installation: installation, now: before)
    precondition(notStarted == .notStarted)
    let finish = try MacOSRemoval.resume(journal: roundTrip, installation: installation, now: after)
    precondition(finish == .finish)
    var complete = roundTrip
    complete["phase"] = "complete"
    let done = try MacOSRemoval.resume(journal: complete, installation: installation, now: after)
    precondition(done == .complete)
    let linux = MacOSRemoval.linuxRecord(roundTrip)
    precondition(
      linux["phase"] as? String == "removed" && linux["kept"] == nil && linux["disk"] == nil)
    for (change, why) in [
      (["phase": "deletin"], "unreadable"), (["espUUID": boot], "another installation"),
      (["installationStoreUUID": root], "another startup container"),
      (["disk": "disk4"], "incomplete"),
    ] as [([String: Any], String)] {
      refused(why) {
        _ = try MacOSRemoval.resume(
          journal: roundTrip.merging(change) { $1 }, installation: installation, now: after)
      }
    }
    for key in ["removedPartitionUUID", "removedContainerUUID", "kept"] {
      var missing = roundTrip
      missing.removeValue(forKey: key)
      refused("incomplete") {
        _ = try MacOSRemoval.resume(journal: missing, installation: installation, now: after)
      }
    }
    var noType = roundTrip
    noType["kept"] = (roundTrip["kept"] as! [[String: Any]]).map { k in
      k.filter { $0.key != "type" }
    }
    refused("incomplete") {
      _ = try MacOSRemoval.resume(journal: noType, installation: installation, now: after)
    }
    refused("doesn’t match the disk") {
      _ = try MacOSRemoval.resume(journal: roundTrip, installation: installation, now: moved)
    }
    // Partition gone but its container still listed, or the reverse: refused.
    let half = WholeDiskLayout(
      disk: "disk0", diskSize: after.diskSize, partitions: after.partitions,
      containers: before.containers)
    refused("half there") {
      _ = try MacOSRemoval.resume(journal: roundTrip, installation: installation, now: half)
    }

    precondition(MacOSRemoval.phrase == "remove macos and all its data")
    precondition(MacOSRemoval.confirms("remove macos and all its data"))
    precondition(MacOSRemoval.confirms("  remove macos and all its data "))
    for wrong in [
      "", "Remove macOS and all its data", "remove macos", "remove macos and all its data.",
    ] {
      precondition(!MacOSRemoval.confirms(wrong), wrong)
    }
    // Owner step: only a finalized account lets removal go ahead; none at all
    // offers account creation, a started one waits for Startup Disk.
    precondition(MacOSRemoval.ownerGate(phase: "finalized") == nil)
    precondition(MacOSRemoval.ownerGate(phase: nil)?.canCreate == true)
    for phase in ["creating", "allocating"] {
      let gate = MacOSRemoval.ownerGate(phase: phase)
      precondition(gate?.canCreate == false && gate?.message.contains("wasn’t finished") == true)
    }
    for phase in ["prepared", "awaiting-ownership", "unknown"] {
      let gate = MacOSRemoval.ownerGate(phase: phase)
      precondition(gate?.canCreate == false && gate?.message.contains("Startup Disk") == true)
    }
    precondition(
      MacOSRemoval.ownerGate(phase: nil)?.message.contains("macOS was not removed") == true)
    precondition(MacOSRemoval.consequences(owner: "user").contains("need user's password"))
    print(
      "PASS macOS removal: plan keeps iSC/stub/ESP/Linux/System Recovery; freed extent; dry-run text; claim record; unchanged/changed review; post-delete verification; phrase; owner step; extra volume, dual macOS, duplicate role refusals; Find My; resume (not started, finish, complete, identity/incomplete/mismatch/half refusals); no-macOS, two-macOS, slot kept, unlisted container, overlap, bad first/last, foreign identity, missing field refusals"
    )
  }
}
