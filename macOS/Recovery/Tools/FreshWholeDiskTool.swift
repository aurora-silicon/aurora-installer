import Foundation

// The fresh whole-disk planner as a command, for replaying an installation on
// disk images (tools/whole-disk/fresh-image-test.py). It reads layouts as
// JSON, never a disk:
//
//   fresh-whole-disk-tool step REQUEST REVIEWED CURRENT
//
// REQUEST holds stubBytes, espBytes, bootBytes, rootMinimumBytes and label.
// A layout holds disk, diskSize, partitions [{identifier, uuid, type,
// offset, size}] and containers [{uuid, reference, storeUUID, volumes [{uuid,
// name, roles, group}]}]. REVIEWED is the reading the person approved (what
// Recovery's journal keeps); CURRENT is the disk now. REVIEWED may be `-`:
// the plan then comes from CURRENT alone, as after a lost journal.
//
// Prints one JSON object: the plan's rows, the next step and, for a creation
// step, the diskutil arguments. Exits 2 with {"refused": message} on a
// refusal; for a laid-out disk the object also has the verified partitions.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(64)
}

func object(_ path: String) -> [String: Any] {
  guard let data = FileManager.default.contents(atPath: path),
    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { fail("can't read \(path)") }
  return value
}

func number(_ value: Any?) -> UInt64 {
  guard let n = value as? NSNumber, n.int64Value >= 0 else { fail("bad number \(String(describing: value))") }
  return n.uint64Value
}

func layout(_ value: [String: Any]) -> WholeDiskLayout {
  let parts = (value["partitions"] as? [[String: Any]] ?? []).map {
    WholeDiskPartition(
      identifier: $0["identifier"] as! String, uuid: ($0["uuid"] as! String).uppercased(),
      type: $0["type"] as! String, offset: number($0["offset"]), size: number($0["size"]))
  }
  let containers = (value["containers"] as? [[String: Any]] ?? []).map { c in
    WholeDiskContainer(
      uuid: (c["uuid"] as! String).uppercased(), reference: c["reference"] as! String,
      storeUUID: (c["storeUUID"] as! String).uppercased(),
      volumes: (c["volumes"] as? [[String: Any]] ?? []).map {
        WholeDiskVolume(
          uuid: ($0["uuid"] as! String).uppercased(), name: $0["name"] as? String ?? "",
          roles: ($0["roles"] as? [String] ?? []).sorted(),
          group: ($0["group"] as? String)?.uppercased())
      })
  }
  return WholeDiskLayout(
    disk: value["disk"] as! String, diskSize: number(value["diskSize"]),
    partitions: parts.sorted { $0.offset < $1.offset }, containers: containers)
}

func emit(_ value: [String: Any], status: Int32 = 0) -> Never {
  let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(data + Data("\n".utf8))
  exit(status)
}

@main struct FreshWholeDiskTool {
  static func main() {
    let args = CommandLine.arguments
    guard args.count == 5, args[1] == "step" else {
      fail("usage: fresh-whole-disk-tool step REQUEST REVIEWED|- CURRENT")
    }
    let r = object(args[2])
    let request = FreshWholeDiskRequest(
      stubBytes: number(r["stubBytes"]), espBytes: number(r["espBytes"]),
      bootBytes: number(r["bootBytes"]), rootMinimumBytes: number(r["rootMinimumBytes"]),
      label: r["label"] as? String ?? "Aurora")
    let current = layout(object(args[4]))
    do {
      let plan = try FreshWholeDisk.plan(
        args[3] == "-" ? current : layout(object(args[3])), request: request)
      if args[3] != "-", plan.macOS != nil, try FreshWholeDisk.next(plan, now: current) == .removeMacOS
      {
        try FreshWholeDisk.requireUnchanged(plan, now: current, request: request)
      }
      var out: [String: Any] = [
        "rows": plan.rows.map { ["role": $0.role.rawValue, "offset": $0.offset, "size": $0.size] },
        "describe": FreshWholeDisk.describe(plan),
      ]
      if let part = plan.macOSPartition { out["macOSPartitionUUID"] = part.uuid }
      switch try FreshWholeDisk.next(plan, now: current) {
      case .removeMacOS:
        out["step"] = "removeMacOS"
        out["arguments"] = ["apfs", "deleteContainer", plan.macOS!.reference]
      case .create(let role, let predecessor):
        out["step"] = "create"
        out["role"] = role.rawValue
        out["arguments"] = FreshWholeDisk.createArguments(
          role, predecessor: predecessor, plan: plan, request: request)
      case .laidOut:
        out["step"] = "laidOut"
        let parts = try FreshWholeDisk.verifyLaidOut(plan, after: current)
        out["verified"] = Dictionary(uniqueKeysWithValues: parts.map { ($0.key.rawValue, $0.value.uuid) })
        out["record"] = FreshWholeDisk.linuxRecord(
          plan, parts: parts, at: Date(timeIntervalSince1970: 0))
      }
      emit(out)
    } catch let refusal as FreshWholeDiskRefusal {
      emit(["refused": refusal.message], status: 2)
    } catch {
      emit(["refused": "\(error)"], status: 2)
    }
  }
}
