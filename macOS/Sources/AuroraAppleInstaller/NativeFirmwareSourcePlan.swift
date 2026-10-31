#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// Firmware collection follows the single identity admitted for the stub.
  struct NativeFirmwareSourcePlan: Sendable {
    struct FUD: Equatable, Sendable {
      let component: String
      let member: String
    }
    let machine: String
    let chipID: UInt64?
    let fud: [FUD]
    let avd: [FUD]
    let kernel: String

    init(manifest: Data) throws {
      guard
        let document = try PropertyListSerialization.propertyList(
          from: manifest, format: nil) as? [String: Any],
        let identities = document["BuildIdentities"] as? [[String: Any]], identities.count == 1,
        let identity = identities.first, let info = identity["Info"] as? [String: Any],
        info["RestoreBehavior"] as? String == "Erase",
        info["Variant"] as? String == "macOS Customer",
        let device = info["DeviceClass"] as? String,
        device.range(of: #"\Aj[0-9]+[a-z]*ap\z"#, options: .regularExpression) != nil,
        let components = identity["Manifest"] as? [String: [String: Any]],
        !components.isEmpty, components.count <= 1024
      else { throw NativeStubFileError.invalidPlan }
      machine = String(device.dropLast(2))
      if let rawChip = identity["ApChipID"] {
        guard let chip = rawChip as? String, chip.hasPrefix("0x"),
          let value = UInt64(chip.dropFirst(2), radix: 16)
        else {
          throw NativeStubFileError.invalidPlan
        }
        chipID = value
      } else {
        chipID = nil
      }
      var selected = [FUD]()
      var selectedAVD = [FUD]()
      let avdComponents = Set(
        chipID.flatMap { AVDFirmware.socs[String(format: "t%04llx", $0)] }?.sources.map(\.component)
          ?? [])
      var kernels = Set<String>()
      for key in components.keys.sorted() {
        guard NativeHandoffEvidence.safeRelative(key), !key.contains("/"),
          let entry = components[key]?["Info"] as? [String: Any],
          let path = entry["Path"] as? String, NativeHandoffEvidence.safeRelative(path)
        else { throw NativeStubFileError.invalidPlan }
        if path.hasPrefix("kernelcache.") { kernels.insert(path) }
        if avdComponents.contains(key) { selectedAVD.append(FUD(component: key, member: path)) }
        for flag in ["IsFUDFirmware", "IsLoadedByiBoot", "IsLoadedByiBootStage1"] {
          if let value = entry[flag], !(value is Bool) { throw NativeStubFileError.invalidPlan }
        }
        if entry["IsFUDFirmware"] as? Bool == true,
          entry["IsLoadedByiBoot"] as? Bool != true,
          entry["IsLoadedByiBootStage1"] as? Bool != true, path.hasSuffix(".im4p")
        {
          selected.append(FUD(component: key, member: path))
        }
      }
      guard kernels.count == 1, let kernel = kernels.first,
        Set(selected.map(\.component)).count == selected.count,
        machine != "j700" || selected.contains(where: { $0.component == "Multitouch" })
      else { throw NativeStubFileError.invalidPlan }
      self.kernel = kernel
      fud = selected
      avd = selectedAVD
    }
  }
#endif
