#if os(macOS)
  import Foundation

  enum NativeStubVolumeError: Error, Equatable {
    case changedContainer, changedVolumes, invalidEvidence
  }

  /// Volume creation is part of the journaled APFS preparation transaction.
  /// No APFS checkpoint is published until the complete group is verified.
  struct NativeStubVolumes: Codable, Equatable, Sendable {
    let planDigest: String
    let partitionUUID: String
    let containerUUID: String
    let label: String
    let volumes: [RemovalVolume]

    static let evidenceIdentifier = "native-stub-volumes"

    var bytes: Data {
      get throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
      }
    }

    static func read(_ data: Data) throws -> Self {
      let result = try JSONDecoder().decode(Self.self, from: data)
      guard try result.bytes == data else { throw NativeStubVolumeError.invalidEvidence }
      return result
    }

    func validate(plan: String, target: RemovalPartition, snapshot: RemovalSnapshot) throws {
      let matches = snapshot.containers.filter { $0.storeUUID == target.uuid }
      guard planDigest == plan, partitionUUID == target.uuid,
        matches.count == 1, let container = matches.first,
        container.uuid == containerUUID, container.volumes == volumes
      else { throw NativeStubVolumeError.changedVolumes }
      try Self.validateComplete(container, label: label)
    }

    static func prepare(
      plan: String, target: RemovalPartition, label: String, snapshot: RemovalSnapshot,
      platform: NativeAPFSPlatform
    ) throws -> Self {
      let matches = snapshot.containers.filter { $0.storeUUID == target.uuid }
      guard matches.count == 1, let initial = matches.first,
        initial.volumes.filter({ $0.roles.isEmpty && $0.name == label }).count == 1,
        initial.volumes.allSatisfy({
          $0.group == nil && [[], ["Preboot"], ["Recovery"], ["VM"]].contains($0.roles)
        }),
        Set(initial.volumes.map(\.uuid)).count == initial.volumes.count
      else { throw NativeStubVolumeError.changedContainer }
      for role in [[], ["Preboot"], ["Recovery"], ["VM"]] {
        guard initial.volumes.filter({ $0.roles == role }).count <= 1 else {
          throw NativeStubVolumeError.changedVolumes
        }
      }
      let dataUUID = initial.volumes.first(where: { $0.roles.isEmpty })!.uuid
      var current = snapshot

      func container(_ state: RemovalSnapshot) throws -> RemovalContainer {
        let matches = state.containers.filter { $0.storeUUID == target.uuid }
        guard state.disk == snapshot.disk,
          let part = state.partitions.first(where: { $0.uuid == target.uuid }), part == target,
          matches.count == 1, let value = matches.first,
          value.uuid == initial.uuid
        else { throw NativeStubVolumeError.changedContainer }
        return value
      }
      func volume(_ uuid: String) throws -> RemovalVolume {
        let matches = try container(current).volumes.filter { $0.uuid == uuid }
        guard matches.count == 1, let result = matches.first,
          validPartition(result.identifier)
        else { throw NativeStubVolumeError.changedVolumes }
        return result
      }
      func mutate(
        _ arguments: [String], admit: (RemovalContainer, RemovalContainer) throws -> Void
      ) throws {
        try Task.checkCancellation()
        let fresh = try platform.snapshot()
        let before = try container(fresh)
        let previous = try container(current)
        guard fresh == current,
          zip(before.volumes, previous.volumes).allSatisfy({ $0.0.identifier == $0.1.identifier })
        else { throw NativeAPFSError.changedLayout }
        try platform.verifyPartition(target, current.disk)
        if arguments.prefix(2) == ["apfs", "addVolume"] {
          guard try platform.containerReference(target, before) == arguments[2] else {
            throw NativeStubVolumeError.changedContainer
          }
        }
        var commandError: (any Error)?
        do { try platform.command(arguments) } catch { commandError = error }
        let after = try platform.snapshot()
        let observed = try container(after)
        var outside = after
        outside.containers.removeAll { $0.uuid == initial.uuid }
        var expected = current
        expected.containers.removeAll { $0.uuid == initial.uuid }
        guard outside == expected else { throw NativeAPFSError.changedLayout }
        // diskutil can fail at mounting after successfully creating a volume.
        // Admit only the exact requested graph change; never replay a command.
        do { try admit(before, observed) } catch { throw commandError ?? error }
        current = after
      }
      func replacing(
        _ before: RemovalContainer, _ after: RemovalContainer, uuid: String,
        name: String, roles: [String]
      ) throws {
        let expected = before.volumes.map { item in
          item.uuid == uuid
            ? RemovalVolume(
              uuid: item.uuid, name: name, roles: roles, group: item.group,
              identifier: item.identifier) : item
        }
        guard after.volumes == expected else { throw NativeStubVolumeError.changedVolumes }
      }

      let data = try volume(dataUUID)
      try mutate(["apfs", "changeVolumeRole", data.identifier, "D"]) { before, after in
        try replacing(before, after, uuid: dataUUID, name: label, roles: ["Data"])
      }
      try mutate(["rename", try volume(dataUUID).identifier, label + " - Data"]) { before, after in
        try replacing(before, after, uuid: dataUUID, name: label + " - Data", roles: ["Data"])
      }
      let reference = try platform.containerReference(target, try container(current))
      try mutate([
        "apfs", "addVolume", reference, "apfs", label, "-role", "S", "-groupWith",
        try volume(dataUUID).identifier,
      ]) { before, after in
        let added = after.volumes.filter { item in !before.volumes.contains { $0.uuid == item.uuid }
        }
        guard added.count == 1, let system = added.first, system.roles == ["System"],
          system.name == label, let group = system.group, validUUID(group),
          group != "00000000-0000-0000-0000-000000000000",
          let data = after.volumes.first(where: { $0.uuid == dataUUID }), data.group == group,
          after.volumes.count == before.volumes.count + 1
        else { throw NativeStubVolumeError.changedVolumes }
        let expected = before.volumes.map { item in
          item.uuid == dataUUID
            ? RemovalVolume(
              uuid: item.uuid, name: item.name, roles: item.roles, group: group,
              identifier: item.identifier) : item
        }
        guard after.volumes.filter({ $0.uuid != system.uuid }) == expected else {
          throw NativeStubVolumeError.changedVolumes
        }
      }
      for (role, short) in [("Preboot", "B"), ("Recovery", "R")] {
        if try container(current).volumes.contains(where: { $0.roles == [role] }) { continue }
        let reference = try platform.containerReference(target, try container(current))
        try mutate(["apfs", "addVolume", reference, "apfs", role, "-role", short]) {
          before, after in
          let added = after.volumes.filter { item in
            !before.volumes.contains { $0.uuid == item.uuid }
          }
          guard added.count == 1, let item = added.first, item.name == role, item.roles == [role],
            item.group == nil, after.volumes.filter({ $0.uuid != item.uuid }) == before.volumes
          else { throw NativeStubVolumeError.changedVolumes }
        }
      }
      let completed = try container(current)
      try validateComplete(completed, label: label)
      return Self(
        planDigest: plan, partitionUUID: target.uuid, containerUUID: completed.uuid,
        label: label, volumes: completed.volumes)
    }

    private static func validPartition(_ value: String) -> Bool {
      value.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func validUUID(_ value: String) -> Bool {
      UUID(uuidString: value)?.uuidString == value
    }

    private static func validateComplete(_ container: RemovalContainer, label: String) throws {
      guard (4...5).contains(container.volumes.count),
        Set(container.volumes.map(\.uuid)).count == container.volumes.count,
        container.volumes.allSatisfy({ validUUID($0.uuid) }),
        container.volumes.allSatisfy({
          [["System"], ["Data"], ["Preboot"], ["Recovery"], ["VM"]].contains($0.roles)
        })
      else { throw NativeStubVolumeError.changedVolumes }
      for role in ["System", "Data", "Preboot", "Recovery"] {
        guard container.volumes.filter({ $0.roles == [role] }).count == 1 else {
          throw NativeStubVolumeError.changedVolumes
        }
      }
      let system = container.volumes.first { $0.roles == ["System"] }!
      let data = container.volumes.first { $0.roles == ["Data"] }!
      guard system.name == label, data.name == label + " - Data",
        let group = system.group, validUUID(group), data.group == group,
        group != "00000000-0000-0000-0000-000000000000",
        container.volumes.filter({ ![system.uuid, data.uuid].contains($0.uuid) })
          .allSatisfy({ $0.group == nil })
      else { throw NativeStubVolumeError.changedVolumes }
    }
  }
#endif
