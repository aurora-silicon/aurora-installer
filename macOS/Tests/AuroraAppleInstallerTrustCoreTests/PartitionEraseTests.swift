#if os(macOS)
  import Foundation
  import XCTest

  @testable import AuroraAppleInstallerTrustCore

  /// Erase on the Partitions screen: a row's partitions are deleted and their
  /// extent stays unallocated, ready to install into. macOS is never resized.
  final class PartitionEraseTests: XCTestCase {
    // MARK: Planning

    func testErasingAnInstallationLeavesItsExtentUnallocatedAndJoinedWithItsNeighbours()
      throws
    {
      let fixture = try Fixture.twoInstallations()
      let plan = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      XCTAssertEqual(plan.kind, .eraseToFreeSpace)
      // The container first, then the rest in disk order; macOS doesn't grow.
      XCTAssertEqual(plan.members.map(\.uuid), Fixture.auroraMembers)
      XCTAssertEqual(plan.targetMacOSBytes, plan.macOS.size)
      XCTAssertNil(plan.startup)
      let ticket = plan.ticket(id: UUID())
      XCTAssertEqual(ticket.kind, .eraseToFreeSpace)
      XCTAssertEqual(ticket.confirmation, "erase these partitions")
      XCTAssertEqual(ticket.reclaimBytes, 0)
      XCTAssertTrue(ticket.erases(exactly: Fixture.auroraMembers.reversed()))
      XCTAssertFalse(ticket.erases(exactly: Array(Fixture.auroraMembers.dropLast())))
      XCTAssertEqual(
        ticket.deletions.map(\.title),
        [
          "Startup container “Aurora Fedora Remix”", "EFI partition “EFI - AUROR”",
          "Linux partition", "Linux partition",
        ])
      XCTAssertEqual(
        ticket.deletions[0].detail,
        "disk0s4 · APFS · volumes “Aurora Fedora Remix”, “Aurora Fedora Remix - Data”, “Preboot”, “Recovery”"
      )
      // The free space before it, the installation and the gap before Fedora
      // become one unallocated extent, as inspection will find it.
      let macOS = try XCTUnwrap(fixture.disk.state.partitions.first { $0.type == "Apple_APFS" })
      let fedora = try XCTUnwrap(
        fixture.disk.state.partitions.first { $0.uuid == Fixture.fedoraStub })
      let freed = NativeInspectionMath.alignDown(fedora.offset - macOS.end)
      XCTAssertEqual(ticket.freedBytes, freed)
      XCTAssertGreaterThan(freed, plan.members.reduce(0) { $0 + $1.size })
      XCTAssertEqual(plan.erased?.freedOffset, macOS.end)
      XCTAssertTrue(plan.summary.contains("macOS isn’t resized"), plan.summary)
      XCTAssertTrue(ticket.kept.contains { $0.detail.hasSuffix("· not resized") })
    }

    func testTheErasedExtentIsOfferedAsAFixedInstallTarget() throws {
      let fixture = try Fixture.twoInstallations()
      let plan = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      var phases = [String]()
      try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(plan) {
        phases.append($0)
      }
      XCTAssertEqual(
        fixture.disk.operations,
        ["container:\(Fixture.auroraStub)"]
          + Fixture.auroraMembers.dropFirst().map { "erase:\($0)" }
      )
      XCTAssertEqual(phases, Fixture.auroraMembers.map { "removing-\($0)" } + ["complete"])
      XCTAssertFalse(fixture.disk.operations.contains { $0.hasPrefix("grow:") })
      // Inspection of the disk afterwards: one free region, which the
      // inventory offers as a free-space candidate of exactly that size.
      let after = try fixture.collect()
      let layout = try NativeDiskLayout(after)
      XCTAssertEqual(
        layout.regions.map(\.kind), [.appleSystem, .macOS, .free, .linux, .free, .appleSystem])
      let freedOffset = try XCTUnwrap(plan.erased?.freedOffset)
      XCTAssertEqual(layout.regions[2].offsetBytes, freedOffset)
      let transcript = try NativeDiskInventory.transcript(
        device: "apple,j414s", snapshot: after.snapshot, containers: after.containers,
        metadata: NativeInspectionPolicy.sealed().baselineMetadata, stubBytes: 2_499_805_184)
      let inventory = try XCTUnwrap(
        AppleInstallerTrustCore().validateEngineTranscript(transcript).inventory)
      let free = try XCTUnwrap(
        inventory.candidates.first { $0.kind == "free" && $0.offsetBytes == freedOffset })
      XCTAssertEqual(free.lengthBytes, plan.erased?.freedBytes)
      // Chosen as the target, it is fixed: Aurora takes all of it.
      let recommendation = try InstallerAllocationRecommendation(
        inventory: inventory, target: .freeSpace(offsetBytes: freedOffset))
      XCTAssertEqual(recommendation.minimumBytes, recommendation.maximumBytes)
      XCTAssertEqual(recommendation.requestedLengthBytes, recommendation.maximumBytes)
      XCTAssertLessThanOrEqual(recommendation.maximumBytes, free.lengthBytes)
      XCTAssertGreaterThan(
        recommendation.maximumBytes + NativePlanRequest.allocationUnitBytes, free.lengthBytes)
    }

    func testAPartitionWithAnotherFileSystemIsErasedAndAnAPFSDataContainerDeleted() throws {
      var fixture = try Fixture.base()
      let windows = fixture.add(
        "Microsoft Basic Data", uuid: Fixture.uuid(501), size: 40 << 30, name: "BOOTCAMP",
        after: 6 << 30)
      let data = fixture.addContainer(
        uuid: Fixture.uuid(601), size: 20 << 30, after: 1 << 30,
        volumes: [RemovalVolume(uuid: Fixture.uuid(611), name: "Archive", roles: [])])
      for (anchor, title, operation) in [
        (windows, "Partition “BOOTCAMP”", "erase:\(windows)"),
        (data, "APFS container “Archive”", "container:\(data)"),
      ] {
        let disk = FakeRemovalDisk(fixture.disk.state, install: nil)
        let collect = fixture.collector(disk)
        let plan = try AuroraRemovalPlan(erasing: anchor, disks: disk, collect: collect)
        XCTAssertEqual(plan.members.map(\.uuid), [anchor])
        XCTAssertEqual(plan.ticket(id: UUID()).deletions.map(\.title), [title])
        // Another file system can't be what the Mac starts up from.
        XCTAssertNil(plan.startup)
        try AuroraRemovalExecutor(disks: disk, collect: collect).execute(plan) { _ in }
        XCTAssertEqual(disk.operations, [operation])
      }
    }

    func testEraseNeverOffersMacOSApplesPartitionsAFullSystemOrABootChainsEFIPartition()
      throws
    {
      var fixture = try Fixture.base()
      // A container with a full system (a Library) but no readable version.
      let full = fixture.addContainer(
        uuid: Fixture.uuid(701), size: 30 << 30, after: 1 << 30,
        volumes: Fixture.systemVolumes("Old macOS", number: 71),
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(719), label: "Old macOS", stub: false, version: nil)
        ])
      // A startup container with no EFI partition of its own, whose
      // bootloader names an EFI partition further along.
      let esp = Fixture.uuid(811)
      fixture.addContainer(
        uuid: Fixture.uuid(801), size: 2_499_805_184, after: 1 << 30,
        volumes: Fixture.systemVolumes("Asahi", number: 81),
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(819), label: "Asahi", stub: true, version: "13.5",
            bootPartitions: [esp])
        ])
      fixture.add("EFI", uuid: esp, size: 500 << 20, name: "EFI - ASAHI", after: 2 << 30)
      fixture.add("Linux Filesystem", uuid: Fixture.uuid(812), size: 4 << 30)
      let disk = FakeRemovalDisk(fixture.disk.state, install: nil)
      let collect = fixture.collector(disk)
      func refusal(_ anchor: String) -> String? {
        do {
          _ = try AuroraRemovalPlan(erasing: anchor, disks: disk, collect: collect)
          return nil
        } catch { return (error as? RemovalFailure)?.message }
      }
      let snapshot = disk.state
      let protected = [
        snapshot.macOSStoreUUID,
        snapshot.partitions.first { $0.type == "Apple_APFS_ISC" }!.uuid,
        snapshot.partitions.first { $0.type == "Apple_APFS_Recovery" }!.uuid,
      ]
      for anchor in protected {
        XCTAssertEqual(refusal(anchor), RemovalText.eraseTargetGone, anchor)
      }
      XCTAssertEqual(
        refusal(full),
        "“Old macOS” is a macOS installation or another full system, and Erase never deletes one. Nothing was changed."
      )
      XCTAssertEqual(
        refusal(esp),
        "“Asahi” starts Linux from the EFI partition disk0s6. Erase “Asahi” together with it. Nothing was changed."
      )
      // The screen offers none of them, for the same reasons.
      let layout = try NativeDiskLayout(collect())
      for region in layout.regions where region.uuid.map([full, esp].contains) == true {
        XCTAssertFalse(region.isErasable)
        XCTAssertNotNil(region.eraseRefusal)
      }
      XCTAssertFalse(layout.regions.contains { $0.kind == .macOS && $0.isErasable })
      XCTAssertFalse(layout.regions.contains { $0.kind == .appleSystem && $0.isErasable })
      // The startup container itself may go; its EFI partition is no longer
      // needed by anything that stays.
      XCTAssertNil(refusal(Fixture.uuid(801)))
      XCTAssertTrue(disk.operations.isEmpty)
    }

    // MARK: Execution

    func testErasingWhatTheMacStartsUpFromSetsMacOSFirst() throws {
      let fixture = try Fixture.twoInstallations()
      fixture.disk.startupState = .other("Aurora Fedora Remix")
      fixture.disk.startupAfterSet = [.success(.macOS)]
      let plan = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      XCTAssertEqual(plan.startup, .other("Aurora Fedora Remix"))
      XCTAssertNotNil(plan.ticket(id: UUID()).startupDisk)
      try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(
        plan, authorization: try authorization()
      ) { _ in }
      XCTAssertEqual(fixture.disk.startupWrites.map(\.afterDeletion), [false])
      XCTAssertEqual(fixture.disk.operations.count, 4)
    }

    func testAStartupChangeSinceReviewStopsAnEraseOfAStartupContainer() throws {
      let fixture = try Fixture.twoInstallations()
      let plan = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      XCTAssertNil(plan.startup)
      // The Mac was set to start up from the installation after review.
      fixture.disk.startupState = .other("Aurora Fedora Remix")
      XCTAssertThrowsError(
        try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(
          plan, authorization: try authorization()
        ) { _ in XCTFail("nothing may be recorded") }
      ) { XCTAssertEqual(($0 as? RemovalFailure)?.message, RemovalText.startupChanged) }
      XCTAssertTrue(fixture.disk.operations.isEmpty)
      XCTAssertTrue(fixture.disk.startupWrites.isEmpty)
    }

    func testARowThatChangedSinceReviewStopsBeforeAnyChange() throws {
      let changes: [(Fixture) -> Void] = [
        // Another partition joined the row.
        { fixture in
          var state = fixture.disk.state
          let last = state.partitions.first { $0.uuid == Fixture.auroraMembers[3] }!
          state.partitions.append(
            RemovalPartition(
              identifier: "disk0s20", uuid: Fixture.uuid(990), type: "Linux Filesystem",
              offset: last.end, size: 1 << 20, name: ""))
          fixture.disk.state = state
        },
        // A container that stays now starts Linux from the row's EFI partition.
        { fixture in
          fixture.facts.value = fixture.facts.value.map { facts in
            guard facts.storeUUID == Fixture.fedoraStub else { return facts }
            return NativeContainerFacts(
              storeUUID: facts.storeUUID, capacity: facts.capacity, free: facts.free,
              preferredMinimum: facts.preferredMinimum,
              systems: facts.systems.map {
                NativeSystemVolumeFacts(
                  group: $0.group, label: $0.label, stub: true, version: $0.version,
                  bootPartitions: [Fixture.auroraMembers[1]])
              })
          }
        },
      ]
      for change in changes {
        let fixture = try Fixture.twoInstallations()
        let plan = try AuroraRemovalPlan(
          erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
        change(fixture)
        XCTAssertThrowsError(
          try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(plan) {
            _ in XCTFail("nothing may be recorded")
          })
        XCTAssertTrue(fixture.disk.operations.isEmpty)
      }
    }

    // MARK: Review findings

    func testABusyVolumeIsRefusedBeforeAnythingIsRecorded() async throws {
      let fixture = try Fixture.twoInstallations()
      fixture.disk.busy = [Fixture.auroraMembers[2]]
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = server(root: root, fixture: fixture)
      let review = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
      let ticket = try XCTUnwrap(review.ticket)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization(),
        erasing: Fixture.auroraStub)
      XCTAssertFalse(result.completed)
      XCTAssertFalse(result.requiresReview)
      XCTAssertTrue(result.message.contains("eject it first"), result.message)
      XCTAssertTrue(result.message.hasSuffix("Nothing was changed."), result.message)
      XCTAssertTrue(fixture.disk.operations.isEmpty)
      let records = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix("removal-") }
      XCTAssertEqual(records, [])
      // Nothing blocks a fresh review.
      _ = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
    }

    func testAFailedFirstDeletionLeavesTheInstallerUsable() async throws {
      for failAt in [1, 2] {
        let fixture = try Fixture.twoInstallations(failAt: failAt)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = server(root: root, fixture: fixture)
        let review = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
        let ticket = try XCTUnwrap(review.ticket)
        let result = try await service.removal(
          ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization(),
          erasing: Fixture.auroraStub)
        XCTAssertFalse(result.completed)
        XCTAssertFalse(result.requiresReview, result.message)
        XCTAssertTrue(
          result.message.contains(failAt == 1 ? "Nothing was erased" : "1 of its 4 partitions"),
          result.message)
        // The disk is the reviewed layout minus what went: a fresh scan
        // plans what is left.
        let next = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil,
          erasing: failAt == 1 ? Fixture.auroraStub : Fixture.auroraMembers[1])
        XCTAssertNotNil(next.ticket, next.message)
      }
    }

    func testAFailedDeletionThatLeftTheDiskUnexpectedStaysForReview() async throws {
      let fixture = try Fixture.twoInstallations()
      fixture.disk.removesThenFails = Fixture.auroraMembers[1]
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = server(root: root, fixture: fixture)
      let review = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
      let ticket = try XCTUnwrap(review.ticket)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization(),
        erasing: Fixture.auroraStub)
      XCTAssertTrue(result.requiresReview, result.message)
      do {
        _ = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.fedoraStub)
        XCTFail("an unexplained layout must block further changes")
      } catch {}
    }

    func testAnUnreadableBootloaderKeepsEveryEFIPartition() throws {
      var fixture = try Fixture.base()
      fixture.addContainer(
        uuid: Fixture.uuid(801), size: 2_499_805_184, after: 1 << 30,
        volumes: Fixture.systemVolumes("Asahi", number: 81),
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(819), label: "Asahi", stub: true, version: "13.5")
        ])
      let esp = fixture.add("EFI", uuid: Fixture.uuid(811), size: 500 << 20, after: 2 << 30)
      fixture.add("Linux Filesystem", uuid: Fixture.uuid(812), size: 4 << 30)
      XCTAssertThrowsError(
        try AuroraRemovalPlan(erasing: esp, disks: fixture.disk, collect: fixture.collect)
      ) {
        XCTAssertEqual(
          ($0 as? RemovalFailure)?.message,
          "The bootloader of “Asahi” couldn’t be read, so any EFI partition might be the one it starts from. Erase “Asahi” first. Nothing was changed."
        )
      }
      // The container itself may still go.
      XCTAssertNoThrow(
        try AuroraRemovalPlan(
          erasing: Fixture.uuid(801), disks: fixture.disk, collect: fixture.collect))
    }

    func testABootObjectThatCantBeReadIsUnknownNotAnInspectionFailure() {
      struct Refusing: RemovalFileReading {
        func read(_ components: [String], limit: Int) throws -> Data? {
          throw RemovalFailure(message: "too large")
        }
      }
      struct Missing: RemovalFileReading {
        func read(_ components: [String], limit: Int) throws -> Data? { nil }
      }
      struct Naming: RemovalFileReading {
        let value: String
        func read(_ components: [String], limit: Int) throws -> Data? {
          Data("STACKBOT\(value)\0".utf8)
        }
      }
      XCTAssertNil(NativeDiskCollector.bootPartitions(Refusing()))
      XCTAssertNil(NativeDiskCollector.bootPartitions(Missing()))
      XCTAssertEqual(NativeDiskCollector.bootPartitions(Naming(value: "other=1")), [])
      XCTAssertEqual(
        NativeDiskCollector.bootPartitions(
          Naming(value: "chosen.asahi,efi-system-partition=\(Fixture.uuid(811).lowercased())")),
        [Fixture.uuid(811)])
    }

    func testApplesPartitionsAreProtectedByPositionToo() throws {
      let base = try Fixture.base()
      var snapshot = base.disk.state
      // Retype Apple's first and last partitions; position still protects them.
      snapshot.partitions = snapshot.partitions.map {
        $0.type == "Apple_APFS_ISC" || $0.type == "Apple_APFS_Recovery"
          ? RemovalPartition(
            identifier: $0.identifier, uuid: $0.uuid, type: "Linux Filesystem",
            offset: $0.offset, size: $0.size, name: $0.name)
          : $0
      }
      // A partition in the gap before macOS.
      let iscEnd = snapshot.partitions.first { $0.type == "Linux Filesystem" }!.end
      snapshot.partitions.append(
        RemovalPartition(
          identifier: "disk0s9", uuid: Fixture.uuid(950), type: "Linux Filesystem",
          offset: iscEnd + 4096, size: 1 << 20, name: ""))
      let disk = NativeCollectedDisk(snapshot: snapshot, containers: base.facts.value)
      for part in snapshot.partitions where part.uuid != snapshot.macOSStoreUUID {
        XCTAssertEqual(
          NativePartitionErase.refusal(members: [part], disk: disk),
          part.uuid == Fixture.uuid(950)
            ? "disk0s9 sits before the macOS you’re running, where Apple keeps its system partitions, so it isn’t erased here."
            : "Apple’s system partitions are never erased.", part.identifier)
      }
    }

    func testAnAPFSContainerThatIsntListedOrLooksLikeMacOSIsKept() throws {
      var fixture = try Fixture.base()
      let unlisted = fixture.add(
        "Apple_APFS", uuid: Fixture.uuid(901), size: 20 << 30, after: 1 << 30)
      var volumes = Fixture.systemVolumes("Looks Stubbed", number: 92)
      volumes.append(RemovalVolume(uuid: Fixture.uuid(928), name: "Update", roles: ["Update"]))
      let swap = fixture.addContainer(
        uuid: Fixture.uuid(902), size: 30 << 30, after: 1 << 30, volumes: volumes,
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(929), label: "Looks Stubbed", stub: true, version: "26.6",
            bootPartitions: [])
        ])
      let disk = try fixture.collect()
      XCTAssertEqual(
        NativePartitionErase.refusal(
          members: disk.snapshot.partitions.filter { $0.uuid == unlisted }, disk: disk),
        "disk0s4 couldn’t be listed as an APFS container, so it can’t be told apart from a macOS installation."
      )
      XCTAssertEqual(
        NativePartitionErase.refusal(
          members: disk.snapshot.partitions.filter { $0.uuid == swap }, disk: disk),
        "“Looks Stubbed” is a macOS installation or another full system, and Erase never deletes one."
      )
    }

    func testTheStartupDiskChangesOnlyWhenTheRowHoldsWhatTheMacStartsFrom() throws {
      let fixture = try Fixture.twoInstallations()
      fixture.disk.startupState = .other("Fedora Linux")
      fixture.disk.startupStoreUUIDs = [Fixture.fedoraStub]
      let aurora = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      XCTAssertNil(aurora.startup)
      XCTAssertNil(aurora.ticket(id: UUID()).startupDisk)
      try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(aurora) {
        _ in
      }
      XCTAssertTrue(fixture.disk.startupWrites.isEmpty)
      let fedora = try AuroraRemovalPlan(
        erasing: Fixture.fedoraStub, disks: fixture.disk, collect: fixture.collect)
      XCTAssertEqual(fedora.startup, .other("Fedora Linux"))
    }

    func testOnlyTheErasedRowsJournalsAreRetired() async throws {
      let fixture = try Fixture.twoInstallations()
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      let aurora = try XCTUnwrap(
        fixture.disk.state.partitions.first { $0.uuid == Fixture.auroraStub })
      let fedora = try XCTUnwrap(
        fixture.disk.state.partitions.first { $0.uuid == Fixture.fedoraStub })
      func journal(_ name: String, offset: UInt64, length: UInt64) throws {
        let line = try JSONSerialization.data(withJSONObject: [
          "type": "plan", "payload": ["offset_bytes": offset, "length_bytes": length],
        ])
        try (line + Data([10])).write(to: journals.appendingPathComponent(name + ".jsonl"))
        try Data("evidence".utf8).write(
          to: journals.appendingPathComponent(name + ".jsonl.apfs-target-prepared.evidence"))
      }
      try journal("a", offset: aurora.offset, length: 8 << 30)
      try journal("b", offset: fedora.offset, length: 8 << 30)
      try Data("not a journal".utf8).write(to: journals.appendingPathComponent("c.jsonl"))
      let service = server(root: root, fixture: fixture)
      let review = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
      let ticket = try XCTUnwrap(review.ticket)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization(),
        erasing: Fixture.auroraStub)
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(
        Set(try FileManager.default.contentsOfDirectory(atPath: journals.path)),
        ["b.jsonl", "b.jsonl.apfs-target-prepared.evidence", "c.jsonl"])
      let retired = root.appendingPathComponent(
        "retired-execution-journals/\(ticket.id.uuidString)")
      XCTAssertEqual(
        Set(try FileManager.default.contentsOfDirectory(atPath: retired.path)),
        ["a.jsonl", "a.jsonl.apfs-target-prepared.evidence"])
    }

    func testARowWithoutAStartupContainerRetiresTheJournalItOverlaps() async throws {
      var fixture = try Fixture.base()
      let esp = fixture.add("EFI", uuid: Fixture.uuid(811), size: 500 << 20, after: 2 << 30)
      fixture.add("Linux Filesystem", uuid: Fixture.uuid(812), size: 4 << 30)
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      let start = try XCTUnwrap(fixture.disk.state.partitions.first { $0.uuid == esp }).offset
      let line = try JSONSerialization.data(withJSONObject: [
        "type": "plan", "payload": ["offset_bytes": start - (2 << 30), "length_bytes": 8 << 30],
      ])
      try (line + Data([10])).write(to: journals.appendingPathComponent("stale.jsonl"))
      let service = server(root: root, fixture: fixture)
      let review = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: esp)
      let ticket = try XCTUnwrap(review.ticket, review.message)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization(),
        erasing: esp)
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journals.path), [])
    }

    func testAStartupContainerWithAVMVolumeIsStillErasableButAFullMacOSIsNot() throws {
      var fixture = try Fixture.base()
      var volumes = Fixture.systemVolumes("Aurora", number: 93)
      volumes.append(RemovalVolume(uuid: Fixture.uuid(938), name: "VM", roles: ["VM"]))
      let stub = fixture.addContainer(
        uuid: Fixture.uuid(903), size: 2_499_805_184, after: 1 << 30, volumes: volumes,
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(939), label: "Aurora", stub: true, version: "26.6",
            bootPartitions: [])
        ])
      var full = Fixture.systemVolumes("Second macOS", number: 94)
      full.append(RemovalVolume(uuid: Fixture.uuid(948), name: "VM", roles: ["VM"]))
      let macOS = fixture.addContainer(
        uuid: Fixture.uuid(904), size: 60 << 30, after: 1 << 30, volumes: full,
        systems: [
          NativeSystemVolumeFacts(
            group: Fixture.uuid(949), label: "Second macOS", stub: false, version: nil)
        ])
      let disk = try fixture.collect()
      func refusal(_ uuid: String) -> String? {
        NativePartitionErase.refusal(
          members: disk.snapshot.partitions.filter { $0.uuid == uuid }, disk: disk)
      }
      XCTAssertNil(refusal(stub))
      XCTAssertEqual(
        refusal(macOS),
        "“Second macOS” is a macOS installation or another full system, and Erase never deletes one."
      )
    }

    func testAnUnparseableEFINameMakesTheBootloaderUnknown() {
      struct Naming: RemovalFileReading {
        func read(_ components: [String], limit: Int) throws -> Data? {
          Data(
            "STACKBOTchosen.asahi,efi-system-partition=not-a-uuid\nchosen.asahi,efi-system-partition=\(Fixture.uuid(811))\0"
              .utf8)
        }
      }
      XCTAssertNil(NativeDiskCollector.bootPartitions(Naming()))
    }

    func testAKeptContainerThatIsntListedKeepsEveryEFIPartition() throws {
      var fixture = try Fixture.base()
      fixture.add("Apple_APFS", uuid: Fixture.uuid(905), size: 20 << 30, after: 1 << 30)
      let esp = fixture.add("EFI", uuid: Fixture.uuid(811), size: 500 << 20, after: 2 << 30)
      fixture.add("Linux Filesystem", uuid: Fixture.uuid(812), size: 4 << 30)
      let disk = try fixture.collect()
      XCTAssertEqual(
        NativePartitionErase.refusal(
          members: disk.snapshot.partitions.filter { [esp, Fixture.uuid(812)].contains($0.uuid) },
          disk: disk),
        "The bootloader of disk0s4 couldn’t be read, so any EFI partition might be the one it starts from. Erase disk0s4 first."
      )
    }

    func testAPartitionBeforeARunningSecondMacOSIsKeptWithItsOwnReason() throws {
      let base = try Fixture.base()
      var snapshot = base.disk.state
      // The running macOS sits after a Linux partition.
      let isc = snapshot.partitions.first { $0.type == "Apple_APFS_ISC" }!
      let linux = RemovalPartition(
        identifier: "disk0s9", uuid: Fixture.uuid(951), type: "Linux Filesystem",
        offset: isc.end + 4096, size: 1 << 20, name: "")
      snapshot.partitions.append(linux)
      let disk = NativeCollectedDisk(snapshot: snapshot, containers: base.facts.value)
      XCTAssertEqual(
        NativePartitionErase.refusal(members: [linux], disk: disk),
        "disk0s9 sits before the macOS you’re running, where Apple keeps its system partitions, so it isn’t erased here."
      )
    }

    func testABusyVolumeLeavesEverythingMountedAgainOrSaysWhatIsnt() throws {
      for failing in [Set<String>(), [Fixture.auroraMembers[0]]] {
        let fixture = try Fixture.twoInstallations()
        fixture.disk.busy = [Fixture.auroraMembers[2]]
        fixture.disk.remountFailures = failing
        let plan = try AuroraRemovalPlan(
          erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
        XCTAssertThrowsError(
          try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(plan) {
            _ in XCTFail("nothing may be recorded")
          }
        ) {
          let message = ($0 as? RemovalFailure)?.message ?? ""
          XCTAssertTrue(message.hasPrefix("“disk0s6” is in use"), message)
          if failing.isEmpty {
            XCTAssertTrue(message.hasSuffix("Nothing was changed."), message)
          } else {
            XCTAssertFalse(message.contains("Nothing was changed."), message)
            XCTAssertTrue(message.contains("still unmounted"), message)
          }
        }
        // The volumes unmounted before the busy one are mounted again.
        XCTAssertEqual(fixture.disk.remounted, Array(Fixture.auroraMembers.prefix(2)))
        XCTAssertTrue(fixture.disk.operations.isEmpty)
      }
    }

    func testARefusedStartupCheckMountsTheUnmountedVolumesAgain() throws {
      let fixture = try Fixture.twoInstallations()
      let plan = try AuroraRemovalPlan(
        erasing: Fixture.auroraStub, disks: fixture.disk, collect: fixture.collect)
      fixture.disk.startupState = .other("Aurora Fedora Remix")
      XCTAssertThrowsError(
        try AuroraRemovalExecutor(disks: fixture.disk, collect: fixture.collect).execute(
          plan, authorization: try authorization()
        ) { _ in }
      )
      XCTAssertEqual(fixture.disk.remounted, Fixture.auroraMembers)
    }

    func testAOneTimeStartupChoiceDoesntHideThePersistentOne() throws {
      let fixture = try Fixture.twoInstallations()
      // Persistent startup from Aurora, a one-time choice of Fedora.
      fixture.disk.startupState = .nextStartupOverride
      fixture.disk.startupStoreUUIDs = [Fixture.auroraStub, Fixture.fedoraStub]
      for stub in [Fixture.auroraStub, Fixture.fedoraStub] {
        let plan = try AuroraRemovalPlan(
          erasing: stub, disks: fixture.disk, collect: fixture.collect)
        XCTAssertEqual(plan.startup, .nextStartupOverride, stub)
      }
    }

    func testReturningFreeSpaceToMacOSRetiresTheJournalOfTheSpaceItTakes() async throws {
      let disk = FakeRemovalDisk(RemovalFixtures.freeSpaceOnly(), install: nil)
      let macOS = try XCTUnwrap(
        disk.state.partitions.first { $0.uuid == disk.state.macOSStoreUUID })
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let journals = root.appendingPathComponent("execution-journals")
      try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
      let line = try JSONSerialization.data(withJSONObject: [
        "type": "plan", "payload": ["offset_bytes": macOS.end, "length_bytes": 64 << 30],
      ])
      try (line + Data([10])).write(to: journals.appendingPathComponent("earlier.jsonl"))
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: NoHandoff(),
        credentialValidator: AcceptingCredentials(), removalDisks: disk,
        removalAdminValidator: { _ in })
      let review = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(review.ticket, review.message)
      XCTAssertEqual(ticket.kind, .freeSpace)
      let result = try await service.removal(
        ticketID: ticket.id, confirmation: ticket.confirmation, authorization: authorization())
      XCTAssertTrue(result.completed, result.message)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: journals.appendingPathComponent("earlier.jsonl").path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent(
            "retired-execution-journals/\(ticket.id.uuidString)/earlier.jsonl"
          ).path))
    }

    // MARK: The helper service

    func testAnEraseTicketRunsOnlyAsThatEraseAndLeavesTheHelperJournalsForOtherRows()
      async throws
    {
      let fixture = try Fixture.twoInstallations()
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let service = server(root: root, fixture: fixture)
      let review = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
      let ticket = try XCTUnwrap(review.ticket)
      XCTAssertTrue(review.message.contains("unallocated free space"), review.message)
      // Neither plain removal nor another row may use it.
      for erasing in [nil, Fixture.fedoraStub] {
        do {
          _ = try await service.removal(
            ticketID: ticket.id, confirmation: ticket.confirmation,
            authorization: authorization(), erasing: erasing)
          XCTFail("the erase ticket ran as \(erasing ?? "removal")")
        } catch {
          XCTAssertTrue(
            (error as? RemovalFailure)?.message.hasPrefix("The confirmation is incorrect") == true)
        }
      }
      XCTAssertTrue(fixture.disk.operations.isEmpty)
      // A fresh review, approved for this row, erases it.
      let fresh = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil, erasing: Fixture.auroraStub)
      let approved = try XCTUnwrap(fresh.ticket)
      let result = try await service.removal(
        ticketID: approved.id, confirmation: approved.confirmation, authorization: authorization(),
        erasing: Fixture.auroraStub.lowercased())
      XCTAssertTrue(result.completed, result.message)
      XCTAssertEqual(
        result.message,
        "“Aurora Fedora Remix” was erased. Its space is now \(RemovalText.size(approved.freedBytes!)) of unallocated free space that you can install into."
      )
      XCTAssertEqual(fixture.disk.operations.count, 4)
    }

    // MARK: Helpers

    private func server(root: URL, fixture: Fixture) -> ClosedEngineHelperServer {
      ClosedEngineHelperServer(
        workingDirectory: root, executor: NoHandoff(),
        credentialValidator: AcceptingCredentials(), removalDisks: fixture.disk,
        removalCollect: fixture.collect, removalAdminValidator: { _ in })
    }

    private func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(username: "test-admin", password: Data("test-password".utf8))
    }

    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "erase-tests-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }
  }

  /// The inspection vector's disk (Apple system container, a 160 GiB macOS
  /// with free space after it, then Recovery) with partitions added before
  /// Recovery, and container facts as the collector reports them.
  private final class Fixture: @unchecked Sendable {
    final class Facts: @unchecked Sendable {
      var value: [NativeContainerFacts]
      init(_ value: [NativeContainerFacts]) { self.value = value }
    }

    static func uuid(_ number: Int) -> String {
      String(format: "00000000-0000-0000-0000-%012d", number)
    }
    static let auroraStub = uuid(400)
    static let auroraMembers = [uuid(400), uuid(410), uuid(420), uuid(430)]
    static let fedoraStub = uuid(800)

    let disk: FakeRemovalDisk
    let facts: Facts
    private var cursor: UInt64
    private var number = 4

    private init(disk: FakeRemovalDisk, facts: [NativeContainerFacts], cursor: UInt64) {
      self.disk = disk
      self.facts = Facts(facts)
      self.cursor = cursor
    }

    var collect: @Sendable () throws -> NativeCollectedDisk { collector(disk) }

    /// A fresh scan of `disk` as it is now.
    func collector(_ disk: FakeRemovalDisk) -> @Sendable () throws -> NativeCollectedDisk {
      let facts = self.facts
      return {
        NativeCollectedDisk(
          snapshot: disk.state,
          containers: facts.value.filter { facts in
            disk.state.partitions.contains { $0.uuid == facts.storeUUID }
          })
      }
    }

    static func base(failAt: Int? = nil) throws -> Fixture {
      let file = try XCTUnwrap(
        Bundle.module.url(
          forResource: "native-inspection-vectors", withExtension: "json",
          subdirectory: "Fixtures"))
      let document =
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
      let vector = (document["vectors"] as! [[String: Any]])[0]
      func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
      }
      var snapshot = try decode(RemovalSnapshot.self, vector["snapshot"]!)
      snapshot.containers.append(
        RemovalContainer(
          uuid: snapshot.macOSContainerUUID, storeUUID: snapshot.macOSStoreUUID,
          volumes: [
            RemovalVolume(
              uuid: "00000000-0000-0000-0000-0000000000C1", name: "Macintosh HD",
              roles: ["System"], group: "00000000-0000-0000-0000-0000000000CA",
              identifier: "disk3s1")
          ]))
      let macOS = snapshot.partitions.first { $0.uuid == snapshot.macOSStoreUUID }!
      return Fixture(
        disk: FakeRemovalDisk(snapshot, install: nil, failAt: failAt),
        facts: try decode([NativeContainerFacts].self, vector["containers"]!), cursor: macOS.end)
    }

    /// Aurora's installation, a gap, then another installer's Fedora right
    /// before Recovery. Each startup container starts from its own ESP.
    static func twoInstallations(failAt: Int? = nil) throws -> Fixture {
      let fixture = try base(failAt: failAt)
      fixture.addInstallation(
        "Aurora Fedora Remix", espName: "EFI - AUROR", at: 40 << 30, base: 400)
      fixture.addInstallation("Fedora Linux", espName: "EFI - FEDOR", at: 1 << 30, base: 800)
      return fixture
    }

    func addInstallation(_ title: String, espName: String, at gap: UInt64, base: Int) {
      let group = Self.uuid(base + 90)
      let sizes: [UInt64] = [2_499_805_184, 524_288_000, 1 << 30, 4 << 30]
      let types = ["Apple_APFS", "EFI", "Linux Filesystem", "Linux Filesystem"]
      cursor += gap
      for index in sizes.indices {
        appendPartition(
          type: types[index], uuid: Self.uuid(base + index * 10), size: sizes[index],
          name: index == 1 ? espName : "")
      }
      var state = disk.state
      state.containers.append(
        RemovalContainer(
          uuid: Self.uuid(base + 80), storeUUID: Self.uuid(base),
          volumes: Self.systemVolumes(title, number: base / 10, group: group)))
      disk.state = state
      facts.value.append(
        NativeContainerFacts(
          storeUUID: Self.uuid(base), capacity: sizes[0], free: 500_000_000, preferredMinimum: 0,
          systems: [
            NativeSystemVolumeFacts(
              group: group, label: title, stub: true, version: "26.6",
              bootPartitions: [Self.uuid(base + 10)])
          ]))
    }

    @discardableResult
    func add(
      _ type: String, uuid: String, size: UInt64, name: String = "", after gap: UInt64 = 0
    ) -> String {
      cursor += gap
      appendPartition(type: type, uuid: uuid, size: size, name: name)
      return uuid
    }

    @discardableResult
    func addContainer(
      uuid: String, size: UInt64, after gap: UInt64, volumes: [RemovalVolume],
      systems: [NativeSystemVolumeFacts] = []
    ) -> String {
      add("Apple_APFS", uuid: uuid, size: size, after: gap)
      var state = disk.state
      state.containers.append(
        RemovalContainer(
          uuid: Self.uuid(Int(uuid.suffix(4))! + 9000), storeUUID: uuid, volumes: volumes))
      disk.state = state
      facts.value.append(
        NativeContainerFacts(
          storeUUID: uuid, capacity: size, free: size / 2, preferredMinimum: 0, systems: systems))
      return uuid
    }

    static func systemVolumes(_ title: String, number: Int, group: String? = nil)
      -> [RemovalVolume]
    {
      let group = group ?? uuid(number * 10 + 9)
      return [
        RemovalVolume(
          uuid: uuid(number * 10 + 1), name: title, roles: ["System"], group: group,
          identifier: "disk\(number)s1"),
        RemovalVolume(
          uuid: group, name: title + " - Data", roles: ["Data"], group: group,
          identifier: "disk\(number)s2"),
        RemovalVolume(
          uuid: uuid(number * 10 + 3), name: "Preboot", roles: ["Preboot"],
          identifier: "disk\(number)s3"),
        RemovalVolume(
          uuid: uuid(number * 10 + 4), name: "Recovery", roles: ["Recovery"],
          identifier: "disk\(number)s4"),
      ]
    }

    private func appendPartition(type: String, uuid: String, size: UInt64, name: String) {
      var state = disk.state
      state.partitions.append(
        RemovalPartition(
          identifier: "disk0s\(number)", uuid: uuid, type: type, offset: cursor, size: size,
          name: name))
      state.partitions.sort { $0.offset < $1.offset }
      disk.state = state
      number += 1
      cursor += size
    }
  }

  private struct AcceptingCredentials: MachineOwnerCredentialValidating {
    func validate(_ authorization: MachineOwnerAuthorization) throws {}
  }

  private struct NoHandoff: ImportedEngineHandoffExecuting {
    func execute(
      _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data { Data() }
  }
#endif
