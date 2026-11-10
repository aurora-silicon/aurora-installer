import Foundation

@main struct InstallConfigurationCheck {
  static func main() throws {
    let value: [String: Any] = [
      "schema": 2, "volumeName": "Aurora Test", "bootstrap": NSNull(),
      "systemUUID": "11111111-1111-4111-8111-111111111111",
      "groupUUID": "22222222-2222-4222-8222-222222222222",
      "prebootUUID": "33333333-3333-4333-8333-333333333333",
      "espUUID": "44444444-4444-4444-8444-444444444444",
      "bootMode": "raw", "stage2Path": "m1n1/boot.bin",
    ]
    let config = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: value))
    precondition(config.volumeName == "Aurora Test" && config.bootMode == "raw")
    // Both Mach-O modes are accepted with their own Stage 2.
    for (mode, path) in [("macho-standard", "m1n1/boot.bin"), ("macho", "m1n1/boot-ctxr.bin")] {
      var current = value
      current["bootMode"] = mode
      current["stage2Path"] = path
      _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: current))
      current["stage2Path"] = path == "m1n1/boot.bin" ? "m1n1/boot-ctxr.bin" : "m1n1/boot.bin"
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: current))
        preconditionFailure("accepted \(mode) with the other Stage 2")
      } catch {}
    }
    for (key, bad) in [
      ("schema", 1), ("schema", true), ("bootMode", "Mach-O"), ("bootMode", "pkg"),
      ("stage2Path", "../boot.bin"), ("systemUUID", "disk0s1"),
      ("espUUID", "00000000-0000-0000-0000-000000000000"),
      ("volumeName", "../macOS"), ("volumeName", "bad\nname"), ("volumeName", ""),
      ("unknown", "unused"), ("allowCustomBootArguments", 1),
      ("allowCustomBootArguments", "true"),
    ] as [(String, Any)] {
      var changed = value
      changed[key] = bad
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted invalid \(key)")
      } catch {}
    }
    precondition(config.allowCustomBootArguments == nil)
    for allowed in [false, true] {
      var scoped = value
      scoped["allowCustomBootArguments"] = allowed
      let decoded = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: scoped))
      precondition(decoded.allowCustomBootArguments == allowed)
    }
    for key in value.keys {
      var changed = value
      changed.removeValue(forKey: key)
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted absent \(key)")
      } catch {}
    }
    var bootstrapped = value
    bootstrapped["bootstrap"] =
      [
        "mode": "source-volume-owner",
        "sourceSystemUUID": "55555555-5555-4555-8555-555555555555",
        "sourceGroupUUID": "66666666-6666-4666-8666-666666666666",
        "ownerUUIDs": ["77777777-7777-4777-8777-777777777777"],
      ] as [String: Any]
    _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: bootstrapped))
    for key in ["mode", "ownerUUIDs", "sourceSystemUUID", "sourceGroupUUID"] {
      var changed = bootstrapped
      var bootstrap = changed["bootstrap"] as! [String: Any]
      bootstrap[key] = "invalid"
      changed["bootstrap"] = bootstrap
      do {
        _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: changed))
        preconditionFailure("accepted invalid bootstrap \(key)")
      } catch {}
    }
    // A Mach-O Stage 1 is always padded and names the confined Stage 2; a raw one never does.
    var macho = value
    macho["bootMode"] = "macho"
    do {
      _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: macho))
      preconditionFailure("accepted a Mach-O installation that loads the standard Stage 2")
    } catch {}
    macho["stage2Path"] = "m1n1/boot-ctxr.bin"
    let confined = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: macho))
    precondition(confined.bootMode == "macho" && confined.stage2Path == "m1n1/boot-ctxr.bin")
    var raw = value
    raw["stage2Path"] = "m1n1/boot-ctxr.bin"
    do {
      _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: raw))
      preconditionFailure("accepted a raw installation that loads the confined Stage 2")
    } catch {}
    macho["stage2Path"] = "m1n1/boot-other.bin"
    do {
      _ = try InstallConfiguration.decode(JSONSerialization.data(withJSONObject: macho))
      preconditionFailure("accepted an unknown Stage 2 path")
    } catch {}
    print(
      "PASS strict per-install configuration, raw and Mach-O modes, Stage 2 path per mode, IDs, paths and missing fields"
    )
  }
}
