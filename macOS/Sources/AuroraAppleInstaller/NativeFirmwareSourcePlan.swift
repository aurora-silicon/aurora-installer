#if os(macOS)
  import Foundation

  /// Firmware collection follows the single identity admitted for the stub:
  /// a restore image's erase identity or an update archive's update identity.
  struct NativeFirmwareSourcePlan: Sendable {
    struct FUD: Equatable, Sendable {
      let component: String
      let member: String
    }
    let machine: String
    let fud: [FUD]
    let kernel: String

    init(manifest: Data) throws {
      guard
        let document = try PropertyListSerialization.propertyList(
          from: manifest, format: nil) as? [String: Any],
        let identities = document["BuildIdentities"] as? [[String: Any]], identities.count == 1,
        let identity = identities.first, let info = identity["Info"] as? [String: Any],
        [NativeRestoreSourceLayout.restoreImage, .updateArchive].contains(where: {
          info["RestoreBehavior"] as? String == $0.restoreBehavior
            && info["Variant"] as? String == $0.variant
        }),
        let device = info["DeviceClass"] as? String,
        device.range(of: #"\A[jk][0-9]+[a-z]*ap\z"#, options: .regularExpression) != nil,
        let components = identity["Manifest"] as? [String: [String: Any]],
        !components.isEmpty, components.count <= 1024
      else { throw NativeStubFileError.invalidPlan }
      machine = String(device.dropLast(2))
      var selected = [FUD]()
      var kernels = Set<String>()
      for key in components.keys.sorted() {
        // Firmware is read from the stub's restore directory, which holds
        // only the components the stub copies; only their paths are used.
        let copied = NativeStubFilePlan.restores(component: key)
        guard NativeHandoffEvidence.safeRelative(key), !key.contains("/"),
          let entry = components[key]?["Info"] as? [String: Any],
          let path = entry["Path"] as? String, !path.isEmpty, !path.contains("\0"),
          !copied || NativeHandoffEvidence.safeRelative(path)
        else { throw NativeStubFileError.invalidPlan }
        guard copied else { continue }
        if path.hasPrefix("kernelcache.") { kernels.insert(path) }
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
    }
  }
#endif
