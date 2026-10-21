#if os(macOS)
  import AuroraFirmware
  import Foundation
  import zlib

  enum NativeBootChainError: Error, Equatable {
    case invalidQualification
    case unsupportedBoard
    case missingStage1
    case missingStage2
    case invalidStage1
  }

  struct NativeBootChainAdmission: Equatable, Sendable {
    let stage1Member: String?
    let windowMilliseconds: UInt32
    let espLayout: [String: String]
  }

  enum NativeBootChain {
    static func admit(
      metadata: Data, archive: IPSWArchive, deviceIdentifier: String, firmware: String
    ) async throws -> NativeBootChainAdmission {
      let template = try NativePayloadPreflight.target(metadata)
      let board = String(deviceIdentifier.dropFirst(6)) + "ap"
      guard deviceIdentifier.hasPrefix("apple,"),
        NativeHandoffEvidence.safeRelative(board)
      else { throw NativeBootChainError.unsupportedBoard }
      for (key, allowed) in [("allowed_device_classes", true), ("excluded_device_classes", false)] {
        if let value = template[key] {
          if value is NSNull {
            guard allowed else { throw NativeBootChainError.unsupportedBoard }
            continue
          }
          guard let values = value as? [String], values.contains(board) == allowed else {
            throw NativeBootChainError.unsupportedBoard
          }
        }
      }
      let members = Dictionary(
        uniqueKeysWithValues: archive.members.filter { !$0.isDirectory }.map {
          ($0.name, $0)
        })
      let qualified = try qualifiedFirmware(template: template, board: board)
      let common = members["esp/aurora/stage1.bin"] != nil && qualified.contains(firmware)
      var stage1: String?
      var window: UInt32 = 0
      if common {
        stage1 = "esp/aurora/stage1.bin"
      } else if board == "j700ap" {
        stage1 = "esp/aurora/stage1-j700.bin"
        window = 5000
      } else if board == "j613ap", firmware == "26.6.2" {
        stage1 = "esp/aurora/stage1-j613.bin"
      }
      if let stage1 {
        guard let member = members[stage1] else { throw NativeBootChainError.missingStage1 }
        let bytes = try await archive.read(member, maximumBytes: 64 << 20)
        _ = try fillStage1(
          bytes, uuid: "00000000-0000-0000-0000-000000000000",
          path: template["next_object"] as? String ?? "m1n1/boot.bin", windowMilliseconds: window)
      }
      let stage2 = try stage2Selection(template: template, board: board)
      let esp = Set(members.keys.filter { $0.hasPrefix("esp/") })
      let layout = try NativeESPLayout.map(
        deviceIdentifier: deviceIdentifier, members: esp, commonAllowed: common,
        stage2: stage2.member,
        stage2Variants: stage2.variants)
      guard let selected = layout.first(where: { $0.value == "m1n1/boot.bin" })?.key,
        let member = members[selected], member.sizeBytes > 0
      else { throw NativeBootChainError.missingStage2 }
      return NativeBootChainAdmission(
        stage1Member: stage1, windowMilliseconds: window, espLayout: layout)
    }

    static func qualifiedFirmware(template: [String: Any], board: String) throws -> [String] {
      guard let policy = template["aurora_stage1"], !(policy is NSNull) else { return [] }
      guard let values = policy as? [String: Any],
        Set(values.keys) == ["kind", "qualified_machines"],
        values["kind"] as? String == "common-raw-v1",
        let machines = values["qualified_machines"] as? [String: [String]]
      else { throw NativeBootChainError.invalidQualification }
      return machines[board] ?? []
    }

    static func stage2Selection(template: [String: Any], board: String) throws -> (
      member: String?, variants: Set<String>
    ) {
      let standard = "esp/m1n1/boot.bin"
      guard let policy = template["aurora_stage2"] else { return (nil, []) }
      guard let values = policy as? [String: Any],
        Set(values.keys) == ["kind", "board_members"],
        values["kind"] as? String == "board-file-v1",
        let boardMembers = values["board_members"] as? [String: String],
        !boardMembers.isEmpty,
        boardMembers.keys.allSatisfy({
          $0.range(of: #"\Aj[0-9]+ap\z"#, options: .regularExpression) != nil
        }),
        boardMembers.values.allSatisfy({
          $0.hasPrefix("esp/m1n1/") && $0.hasSuffix(".bin")
            && NativeHandoffEvidence.safeRelative($0)
        }),
        Set(boardMembers.values).count == boardMembers.count
      else { throw NativeBootChainError.invalidQualification }
      return (boardMembers[board] ?? standard, Set(boardMembers.values).union([standard]))
    }

    static func fillStage1(
      _ image: Data, uuid: String, path: String, windowMilliseconds: UInt32
    ) throws -> Data {
      let magic = Data("AURORA-S1-CFG01\0".utf8)
      let blockBytes = magic.count + 240 + 4
      guard
        uuid.range(
          of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#,
          options: .regularExpression) != nil,
        NativeHandoffEvidence.safeRelative(path),
        path.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f && $0 != 0x3b }),
        path.utf8.count + 1 < 192, windowMilliseconds <= 99999,
        image.suffix(8) == Data("STACKBOT".utf8),
        let range = image.range(of: magic),
        image.range(of: magic, in: (range.lowerBound + 1)..<image.count) == nil,
        range.lowerBound <= image.count - 8 - blockBytes
      else { throw NativeBootChainError.invalidStage1 }
      let offset = range.upperBound
      guard image[offset..<(offset + 4)].elementsEqual([1, 0, 0, 0]) else {
        throw NativeBootChainError.invalidStage1
      }
      var body = Data([1, 0, 0, 0])
      body.append(
        contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: windowMilliseconds >> ($0 * 8)) })
      body.append(Data(uuid.utf8))
      body.append(Data(repeating: 0, count: 4))
      let encoded = Data((";" + path).utf8)
      body.append(encoded)
      body.append(Data(repeating: 0, count: 192 - encoded.count))
      let crc = body.withUnsafeBytes {
        UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)))
      }
      body.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
      var result = Data(image.prefix(range.lowerBound))
      result.append(magic)
      result.append(body)
      result.append(image.suffix(from: range.lowerBound + blockBytes))
      return result
    }
  }

  enum NativeESPLayout {
    static func map(
      deviceIdentifier: String, members: Set<String>, commonAllowed: Bool, stage2: String?,
      stage2Variants: Set<String>
    ) throws -> [String: String] {
      let standard = "esp/m1n1/boot.bin"
      let board = String(deviceIdentifier.dropFirst(6))
      let conventional = "esp/m1n1/boot-\(board).bin"
      let selected = stage2 ?? (members.contains(conventional) ? conventional : standard)
      let common = members.contains("esp/aurora/stage1.bin") && commonAllowed
      guard members.contains(selected)
      else { throw NativeHandoffValidationError.changedContent }
      var layout = [String: String]()
      for member in members.sorted() {
        guard member.hasPrefix("esp/"), NativeHandoffEvidence.safeRelative(member) else {
          throw NativeHandoffValidationError.unsafePath
        }
        if member == selected {
          layout[member] = "m1n1/boot.bin"
        } else if (member == "esp/aurora/stage1.bin" && !common)
          || stage2Variants.contains(member)
          || (member.hasPrefix("esp/m1n1/boot-") && member.hasSuffix(".bin"))
          || (common
            && ["esp/aurora/stage1-j700.bin", "esp/aurora/stage1-j613.bin"].contains(member))
        {
          continue
        } else {
          layout[member] = String(member.dropFirst(4))
        }
      }
      guard !layout.isEmpty, Set(layout.values).count == layout.count else {
        throw NativeHandoffValidationError.changedContent
      }
      return layout
    }
  }
#endif
