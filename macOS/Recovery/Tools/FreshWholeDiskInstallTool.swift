import Foundation

// aurora-fresh-install: the disk stage of a fresh whole-disk installation,
// run as root in System Recovery (macOS's own Recovery lives in the container
// being deleted, and the stage refuses to run from it). It removes macOS and
// lays out
// [iSC][startup container][EFI][Boot][Root][System Recovery], writing the
// release's pinned boot and root images.
//
//   aurora-fresh-install --request REQUEST.json --journal PATH [--dry-run]
//
// REQUEST holds stubBytes, espBytes, bootBytes, rootMinimumBytes, label,
// espLabel, espVolumeID and boot/root {source, size, sha256}: the values the
// release's signed metadata gives. The phrase is read from standard input.
// Exit 0 laid out (or dry run), 1 failed, 2 refused (nothing changed).

@main struct FreshWholeDiskInstallTool {
  static func main() {
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String? {
      guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
      let v = args[i + 1]
      args.removeSubrange(i...i + 1)
      return v
    }
    let dryRun = args.contains("--dry-run")
    args.removeAll { $0 == "--dry-run" }
    var tools = FreshWholeDiskTools()
    #if FRESH_WHOLE_DISK_TEST
      // Disk-image tests only: stand-in tools and an image file for disk0.
      if let dir = value("--test-tools"), let image = value("--test-image") {
        tools.diskutil = dir + "/diskutil"
        tools.newfsMSDOS = dir + "/newfs_msdos"
        tools.device = { (image, $0.offset) }
      }
    #endif
    guard let requestPath = value("--request"), let journal = value("--journal"), args.isEmpty,
      let data = FileManager.default.contents(atPath: requestPath),
      let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      FileHandle.standardError.write(
        Data("usage: aurora-fresh-install --request REQUEST.json --journal PATH [--dry-run]\n".utf8))
      exit(64)
    }
    // Every value comes from the release's metadata; a missing or negative
    // one is 0, which the planner refuses.
    func n(_ v: Any?) -> UInt64 {
      guard let x = v as? NSNumber, x.int64Value > 0 else { return 0 }
      return x.uint64Value
    }
    guard let disk = r["disk"] as? String, let label = r["label"] as? String, !label.isEmpty,
      let espLabel = r["espLabel"] as? String, !espLabel.isEmpty
    else {
      FileHandle.standardError.write(Data("The request needs disk, label and espLabel.\n".utf8))
      exit(64)
    }
    func image(_ v: Any?) -> FreshWholeDiskImage {
      let d = v as? [String: Any] ?? [:]
      return FreshWholeDiskImage(
        source: d["source"] as? String ?? "", size: n(d["size"]), sha256: d["sha256"] as? String ?? "")
    }
    let request = FreshWholeDiskRequest(
      stubBytes: n(r["stubBytes"]), espBytes: n(r["espBytes"]), bootBytes: n(r["bootBytes"]),
      rootMinimumBytes: n(r["rootMinimumBytes"]), label: label)
    func say(_ s: String) { print(s) }
    do {
      if dryRun {
        let plan = try FreshWholeDisk.plan(FreshWholeDiskInstall.read(disk, tools: tools), request: request)
        say(FreshWholeDisk.describe(plan))
        say("Dry run: nothing was changed.")
        exit(0)
      }
      try FreshWholeDiskInstall.install(
        disk: disk, request: request, boot: image(r["boot"]), root: image(r["root"]),
        espLabel: espLabel, espVolumeID: r["espVolumeID"] as? String,
        journalURL: URL(fileURLWithPath: journal),
        confirmed: { plan in
          say(FreshWholeDisk.consequences())
          say("Type “\(FreshWholeDisk.phrase)” to continue:")
          return FreshWholeDisk.phrase == (readLine() ?? "").trimmingCharacters(in: .whitespaces)
        }, tools: tools, log: say)
      say("Disk stage finished.")
    } catch let refusal as FreshWholeDiskRefusal {
      FileHandle.standardError.write(Data(("Refused: " + refusal.message + "\n").utf8))
      exit(2)
    } catch {
      FileHandle.standardError.write(Data(("Failed: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
}
