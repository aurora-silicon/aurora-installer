// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import AuroraFirmware

struct NeoRegulatoryPolicyV2Tests {
  private struct Fixture: Decodable {
    let inputs: [String: String]
    let outputs: [String: String]
  }
  private func fixture() throws -> Fixture {
    let url = try #require(
      Bundle.module.url(
        forResource: "regulatory-synthetic", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  private let groups = ["ofdm", "ru26", "ru52", "ru106", "ru242", "ru484", "ru996", "ru996X2"]
  private let channels =
    [2]
    + (1...233).filter {
      $0 != 231 && $0 & 1 == 1 && NeoRegulatoryPolicy.width6($0) != 255
    }
  private func synthetic(vlp: Bool = true, numeric: Bool = true, permission: String = "2") throws
    -> [String: Data]
  {
    var inputs = try fixture().inputs
    let legacy = inputs["IZUBA_TxPwrLimit_MT79x1.dat"]!
    var table =
      NeoRegulatoryPolicy.versions["IZUBA_TxPwrLimit6G_MT79x1.dat"]!
      + "\n<Ver:03>\n[US,\(vlp ? "VLP" : "LP")]\n"
    for group in groups {
      let header = try #require(
        legacy.components(separatedBy: .newlines).first { $0.hasPrefix("<" + group + ",") })
      let count = group == "ofdm" ? 8 : 36
      table +=
        header + "\nch001,"
        + Array(repeating: numeric ? "24" : "X", count: count).joined(separator: ",") + "\n"
      if group == "ofdm" {
        table += "ch002," + (1...8).map(String.init).joined(separator: ",") + "\n"
      }
      table += "</\(group)>\n"
    }
    inputs["IZUBA_TxPwrLimit6G_MT79x1.dat"] = table
    var database = inputs["IZUBA_db.dat"]!.components(separatedBy: .newlines)
    var six = false
    for index in database.indices {
      if database[index].hasPrefix("<6gCC,") {
        database[index] =
          "<6gCC," + channels.map { "6g\($0)" }.joined(separator: ",")
          + ",vht40,vht80,vht160,c2clpi,vlpp2p,flag>"
        six = true
      } else if six && database[index].hasPrefix("</") {
        six = false
      } else if six && !database[index].isEmpty {
        let country = database[index].components(separatedBy: ",")[0]
        database[index] =
          country + "," + Array(repeating: permission, count: 110).joined(separator: ",")
          + ",0,0,0,0,0,0,"
      }
    }
    inputs["IZUBA_db.dat"] = database.joined(separator: "\n")
    return inputs.mapValues { Data($0.utf8) }
  }

  @Test func unchangedV1ReferenceAndProductionAuthentication() throws {
    let fixture = try fixture()
    let outputs = try NeoRegulatoryPolicy.derive(
      fixture.inputs.mapValues { Data($0.utf8) }, authenticated: false)
    #expect(outputs.mapValues(\.sha256) == fixture.outputs)
    #expect(outputs.count == 5)
    #expect(throws: (any Error).self) {
      try NeoRegulatoryPolicy.derive(fixture.inputs.mapValues { Data($0.utf8) })
    }
  }

  @Test func v2UsesSeparatePathAndRetainsEveryV1Byte() throws {
    let outputs = try NeoRegulatoryPolicy.derive(synthetic(), authenticated: false)
    let v1 = try #require(outputs["mediatek/mt7932/policy/US.bin"])
    let v2 = try #require(outputs["mediatek/mt7932/policy-v2/US.bin"])
    #expect(outputs.count == 6)
    #expect(outputs["mediatek/mt7932/policy-v2/world-XZ.bin"] == nil)
    #expect(v2.count == v1.count + 18418)
    var restored = Data(v2.prefix(v1.count))
    restored.replaceSubrange(4..<6, with: [1, 0])
    restored.replaceSubrange(12..<16, with: littleBytes(v1.count, count: 4))
    #expect(restored == v1)
    #expect(try NeoFirmwareConversions.policy(v2, country: "US") == v2)
    #expect(try v2.part(v1.count, 8) == Data("6GRP".utf8) + Data([1, 14, 28, 0]))
    // Only ch001 has numeric primary data; ch002 is never a permission bit.
    #expect(try v2.little(v1.count + 8, 8) == 1)
    let first = v1.count + 24 + 4
    #expect(v2[first + 44] == 2)
    // Literal descriptor offsets 0x00d/0x025, not dense group boundaries.
    #expect(try v2.part(first + 45, 7) == Data([196, 1, 5, 7, 2, 6, 8]))
    // The second native page begins with association selector 0x0f.
    #expect(v2[first + 1024 + 44] == 15)
    #expect(
      v2
        == (try NeoRegulatoryPolicy.derive(synthetic(), authenticated: false))[
          "mediatek/mt7932/policy-v2/US.bin"])
  }

  @Test func eligibilityRequiresVLPMatrixAndNumericPrimaryIntersection() throws {
    for inputs in [
      try synthetic(vlp: false), try synthetic(numeric: false), try synthetic(permission: "1/3"),
    ] {
      let outputs = try NeoRegulatoryPolicy.derive(inputs, authenticated: false)
      #expect(!outputs.keys.contains { $0.contains("policy-v2/") })
      #expect(outputs.count == 5)
    }
    let outputs = try NeoRegulatoryPolicy.derive(
      synthetic(permission: "1/2/3"), authenticated: false)
    #expect(outputs["mediatek/mt7932/policy-v2/US.bin"] != nil)
  }

  @Test func parserRejectsMalformedV2BeforePublication() throws {
    let outputs = try NeoRegulatoryPolicy.derive(synthetic(), authenticated: false)
    let v1 = try #require(outputs["mediatek/mt7932/policy/US.bin"])
    let v2 = try #require(outputs["mediatek/mt7932/policy-v2/US.bin"])
    let ext = v1.count
    let first = v1.count + 28
    let changes: [(Int, UInt8)] = [
      (4, 3), (6, 65), (10, 1), (12, 0),
      (ext, 0), (ext + 4, 2), (ext + 5, 15), (ext + 6, 0), (ext + 6, 33),
      (ext + 7, 1), (ext + 8, 0), (ext + 15, 8), (ext + 16, 65), (ext + 18, 0), (ext + 23, 1),
      (first - 4, 0), (first - 3, 1), (first, 0), (first + 1, 10), (first + 2, 0),
      (first + 4, 7), (first + 5, 2), (first + 6, 2), (first + 7, 1), (first + 8, 65),
      (first + 10, 1), (first + 44, 1), (first + 1024 + 44, 2),
      (first + 14092, 1),  // first legacy body's reserved byte
    ]
    for (offset, value) in changes {
      var bytes = v2
      #expect(bytes[offset] != value)
      bytes[offset] = value
      #expect(throws: (any Error).self) { try NeoFirmwareConversions.policy(bytes, country: "US") }
    }
    for count in [0, 15, ext + 23, v2.count - 1] {
      #expect(throws: (any Error).self) {
        try NeoFirmwareConversions.policy(Data(v2.prefix(count)), country: "US")
      }
    }
    var trailing = v2 + Data([0])
    trailing.replaceSubrange(12..<16, with: littleBytes(trailing.count, count: 4))
    #expect(throws: (any Error).self) { try NeoFirmwareConversions.policy(trailing, country: "US") }
  }

  @Test func invalidSixGHzSchemaFailsClosed() throws {
    let inputs = try synthetic()
    for (from, to) in [
      ("[US,VLP]", "[US,AFC]"), ("ch001,24", "ch231,24"),
      ("ch001,24", "ch001,128"), ("</ru26>", "</ru52>"), ("6g233", "6g231"),
      ("</ru996X2>", "</ru996X2>\n<ofdm,o6>\n</ofdm>"),
    ] {
      var changed = inputs
      var found = false
      for (name, bytes) in inputs {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.contains(from) {
          changed[name] = Data(text.replacingOccurrences(of: from, with: to).utf8)
          found = true
        }
      }
      #expect(found)
      #expect(throws: (any Error).self) {
        try NeoRegulatoryPolicy.derive(changed, authenticated: false)
      }
    }
  }

  @Test func liveSelectionIsAtomicAndVersionMismatchFallsBack() throws {
    let inputs = try fixture().inputs.mapValues { Data($0.utf8) }
    let hashes = inputs.mapValues(\.sha256)
    #expect(try NeoRegulatoryPolicy.matchingInputs(hashes: hashes) { inputs[$0]! } == inputs)
    var reads = 0
    let missing = try NeoRegulatoryPolicy.matchingInputs(hashes: hashes) { name in
      reads += 1
      if name == "IZUBA_db.dat" { throw RestoreFailure("missing") }
      return inputs[name]!
    }
    #expect(missing == nil && reads > 0)
    var changed = inputs
    changed["IZUBA_db.dat"] = Data(
      String(decoding: inputs["IZUBA_db.dat"]!, as: UTF8.self)
        .replacingOccurrences(of: "Snrs_V2.0", with: "Snrs_V3.0").utf8)
    #expect(try NeoRegulatoryPolicy.matchingInputs(hashes: hashes) { changed[$0]! } == nil)
    // Even when a caller supplies a matching test hash, the version gate is independent.
    #expect(
      try NeoRegulatoryPolicy.matchingInputs(hashes: changed.mapValues(\.sha256)) { changed[$0]! }
        == nil)
    var cancelled = false
    do {
      _ = try NeoRegulatoryPolicy.matchingInputs(hashes: hashes) { _ in throw CancellationError() }
    } catch is CancellationError { cancelled = true }
    #expect(cancelled)
  }

  @Test func inventoryRejectsChangesMissingAndExtraCountries() throws {
    let outputs = ["policy-v2/US.bin": Data([1]), "policy-v2/AU.bin": Data([2])]
    let expected = NeoRegulatoryPolicy.inventoryDigest(outputs)
    #expect(
      expected
        == Data(
          "policy-v2/AU.bin\t\(Data([2]).sha256)\npolicy-v2/US.bin\t\(Data([1]).sha256)\n".utf8
        ).sha256)
    try NeoRegulatoryPolicy.verifyOutputs(outputs, pins: [:], inventory: expected)
    for changed in [
      outputs.filter { $0.key != "policy-v2/AU.bin" },
      outputs.merging(["policy-v2/CA.bin": Data([3])]) { _, b in b },
      outputs.merging(["policy-v2/US.bin": Data([4])]) { _, b in b },
    ] {
      #expect(throws: (any Error).self) {
        try NeoRegulatoryPolicy.verifyOutputs(changed, pins: [:], inventory: expected)
      }
    }
  }

  @Test func preferredTablesPruneOnlyTheirIPSWDependencies() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "j700-25G83-ranges", withExtension: "json", subdirectory: "Fixtures"))
    let recipe = try strictRecipe(Data(contentsOf: url))
    let network = try networkRecipe(recipe, preferred: [:])
    var syntheticRecipe = recipe
    let index = try #require(
      syntheticRecipe.files.firstIndex {
        $0.name == "sunrise/IZUBA_TxPwrLimit_MT79x1.dat"
      })
    let name = syntheticRecipe.files[index].name
    syntheticRecipe.files[index].size = 1
    syntheticRecipe.files[index].sha256 = Data([1]).sha256
    syntheticRecipe.files[index].rawSHA256 = Data([1]).sha256
    let local = try networkRecipe(syntheticRecipe, preferred: [name: Data([1])])
    #expect(local.files.count == recipe.files.count - 1)
    #expect(!local.files.contains { $0.name == name })
    #expect(local.segments.count < recipe.segments.count)
    try local.validate()
    #expect(network.files.count == recipe.files.count)
    #expect(network.segments.count == recipe.segments.count)
    #expect(throws: (any Error).self) {
      try networkRecipe(recipe, preferred: ["sunrise/IZUBA_db.dat": Data([0])])
    }
    #expect(throws: (any Error).self) {
      try networkRecipe(recipe, preferred: ["unexpected": Data([0])])
    }
  }

  @Test func liveTablesReproduceBothInventories() throws {
    guard ProcessInfo.processInfo.environment["AURORA_LIVE_POLICY_TEST"] == "1" else { return }
    let inputs = try #require(try NeoRegulatoryPolicy.liveInputs())
    let outputs = try NeoRegulatoryPolicy.derive(inputs)
    let v1 = outputs.filter { $0.key.contains("/policy/") }
    let v2 = outputs.filter { $0.key.contains("/policy-v2/") }
    #expect(v1.count == 244 && v2.count == 120)
    #expect(NeoRegulatoryPolicy.inventoryDigest(v1) == NeoRegulatoryPolicy.outputInventorySHA256)
    let relative = Dictionary(
      uniqueKeysWithValues: v2.map {
        (String($0.key.dropFirst("mediatek/mt7932/".count)), $0.value)
      })
    #expect(
      NeoRegulatoryPolicy.inventoryDigest(relative) == NeoRegulatoryPolicy.outputV2InventorySHA256)
    #expect(
      v2["mediatek/mt7932/policy-v2/AU.bin"]?.sha256
        == "3425de282eb1a3c2c76d8cd65a31305e92f0e5b481d65096c0faa1ac631fea27")
    let references = [
      "US": "32065c3c721bb75cadaabf3599fdb202fcd292832024ef22b83e7da153761e06",
      "CA": "cbf3365030acd6db08e568a8e969d1273e0e40699c3b3a1919bcce6f47067396",
      "DE": "0c6545eb24e02233566c551aee7bff3aefb9e7b08e86431d331a30c5ca0fc5f5",
    ]
    for (country, sha) in references {
      #expect(v2["mediatek/mt7932/policy-v2/" + country + ".bin"]?.sha256 == sha)
    }
    let plan = try FirmwareExtractionPlan.bundled(for: "apple,j700")
    let preferred = Dictionary(uniqueKeysWithValues: inputs.map { ("sunrise/" + $0.key, $0.value) })
    let pruned = try networkRecipe(plan.recipe, preferred: preferred)
    #expect(pruned.files.count == plan.recipe.files.count - 6)
    #expect(pruned.segments.count < plan.recipe.segments.count)
    print("Local policy qualification: v1=244, v2=120, both pinned inventories verified")
  }
  @Test func vendorFirmwareKeepsBothPolicyDirectories() throws {
    let outputs = try NeoRegulatoryPolicy.derive(synthetic(), authenticated: false)
    let archives = try FirmwarePackageBuilder.build(
      outputs.keys.sorted().map {
        FirmwarePackageInput(name: $0, bytes: outputs[$0]!)
      })
    for name in outputs.keys {
      #expect(archives.tar.range(of: Data(name.utf8)) != nil)
      #expect(archives.cpio.range(of: Data(("vendorfw/" + name).utf8)) != nil)
      #expect(archives.manifest.range(of: Data(name.utf8)) != nil)
    }
  }

  @Test func peripheralGateAllowsNonUSAndStillRequiresWorld() throws {
    let macOS = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scriptURL = macOS.appendingPathComponent(
      "image-builder/firmware-ordering/aurora-peripheral-firmware.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    let hook = try String(
      contentsOf: macOS.appendingPathComponent(
        "image-builder/firmware-ordering/aurora-vendor-order.install"), encoding: .utf8)
    #expect(!script.contains("policy/US.bin") && !hook.contains("policy/US.bin"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let firmware = root.appendingPathComponent("firmware")
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("modprobe.log")
    let mock = bin.appendingPathComponent("modprobe")
    try Data("#!/bin/bash\necho \"$1\" >> \"$PROBE_LOG\"\n".utf8).write(to: mock)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
    let compatible = root.appendingPathComponent("compatible")
    try Data("apple,j700\0".utf8).write(to: compatible)
    var required = NeoFirmwareConversions.requiredRadioNames
    required.formUnion([
      NeoFirmwareConversions.alsName, "apple/tpmtfw-j700.bin",
      "mediatek/mt7932/policy/world-XZ.bin", "mediatek/mt7932/policy/AU.bin",
    ])
    for name in required {
      let file = firmware.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([1]).write(to: file)
    }
    let adapted = script.replacingOccurrences(of: "/lib/firmware/vendor", with: firmware.path)
      .replacingOccurrences(of: "/lib/firmware", with: firmware.path)
      .replacingOccurrences(of: "/sys/firmware/devicetree/base/compatible", with: compatible.path)
    let executable = root.appendingPathComponent("gate.sh")
    try Data(adapted.utf8).write(to: executable)
    func run() throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [executable.path]
      process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "PROBE_LOG": log.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }
    #expect(try run() == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "aop\nmt7932-fullmac\n")
    try FileManager.default.removeItem(at: log)
    try FileManager.default.removeItem(
      at: firmware.appendingPathComponent("mediatek/mt7932/policy/world-XZ.bin"))
    #expect(try run() != 0)
    #expect(!FileManager.default.fileExists(atPath: log.path))
    try Data("apple,j274\0".utf8).write(to: compatible)
    #expect(try run() == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "aop\n")
  }

}
