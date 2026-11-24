// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import AuroraFirmware

struct RadioFirmwareRestoreImagesTests {
  /// A structurally valid recipe for a made-up board: the J700 fixture's
  /// ranges with its files renamed under the Wi-Fi tree. No Apple data.
  private func recipe(board: String, rename: Bool = true) throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: "j700-25G83-ranges", withExtension: "json", subdirectory: "Fixtures"))
    var document = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var files = try #require(document["files"] as? [[String: Any]])
    if rename {
      for index in files.indices {
        let name = RadioFirmwareSource.wifiPath + "/C-9999__s-Z9/\(board)-X\(index).trx"
        files[index]["name"] = name
        files[index]["source"] = name
      }
    }
    document["files"] = files
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
  }

  private func index(_ recipe: Data, boards: [String: String], recipes: [String: String]) throws
    -> (Data, URL)
  {
    let document = try #require(try JSONSerialization.jsonObject(with: recipe) as? [String: Any])
    let source = try #require(document["source"] as? [String: Any])
    let url = try #require(source["url"] as? String)
    let image: [String: Any] = [
      "build": "00A001", "url": url, "size_bytes": source["size_bytes"]!,
      "sha256": source["sha256"]!, "boards": boards, "recipes": recipes,
    ]
    let index = try JSONSerialization.data(
      withJSONObject: [
        "schema": 1, "kind": "aurora-radio-firmware-restore-images", "images": [image],
      ] as [String: Any], options: [.sortedKeys])
    return (index, try #require(URL(string: url)))
  }

  @Test func theStubImageNamesTheBoardAndItsRecipe() throws {
    let good = try recipe(board: "zzboard")
    let (pin, url) = try index(
      good, boards: ["j999ap": "zzboard"], recipes: ["zzboard": good.sha256])
    let recipes = ["00A001-zzboard.json": good]
    let source = try RadioFirmwareRestoreImages.source(
      stubSource: url, machine: "j999", board: "zzboard", index: pin, recipes: recipes)
    #expect(source.build == "00A001" && source.board == "zzboard")
    #expect(source.plan.recipeSHA256 == good.sha256)
    // Another board, another model, another image, a changed recipe.
    let other = try #require(URL(string: "https://updates.cdn-apple.com/x/Other_Restore.ipsw"))
    let failures: [() throws -> RadioFirmwareSource] = [
      {
        try RadioFirmwareRestoreImages.source(
          stubSource: url, machine: "j999", board: "other", index: pin, recipes: recipes)
      },
      {
        try RadioFirmwareRestoreImages.source(
          stubSource: url, machine: "j998", board: "zzboard", index: pin, recipes: recipes)
      },
      {
        try RadioFirmwareRestoreImages.source(
          stubSource: other, machine: "j999", board: "zzboard", index: pin, recipes: recipes)
      },
      {
        try RadioFirmwareRestoreImages.source(
          stubSource: url, machine: "j999", board: "zzboard", index: pin,
          recipes: ["00A001-zzboard.json": good + Data([0x20])])
      },
    ]
    for failure in failures {
      #expect(throws: (any Error).self) { try failure() }
    }
    // A recipe of other files.
    let foreign = try recipe(board: "zzboard", rename: false)
    let (foreignPin, _) = try index(
      foreign, boards: ["j999ap": "zzboard"], recipes: ["zzboard": foreign.sha256])
    #expect(throws: (any Error).self) {
      try RadioFirmwareRestoreImages.source(
        stubSource: url, machine: "j999", board: "zzboard", index: foreignPin,
        recipes: ["00A001-zzboard.json": foreign])
    }
  }

  /// The compiled-in list: every model it names resolves to a recipe that
  /// passes admission.
  @Test func theCompiledInListResolvesEveryModel() throws {
    let pin = try RadioFirmwareRestoreImages.index(RadioFirmwareRestoreImages.embeddedIndex())
    var count = 0
    for image in pin.images {
      let url = try #require(URL(string: image.url))
      #expect(try RadioFirmwareRestoreImages.covers(stubSource: url))
      for (device, board) in image.boards {
        let source = try RadioFirmwareRestoreImages.source(
          stubSource: url, machine: String(device.dropLast(2)), board: board)
        #expect(source.build == image.build && !source.plan.outputs.isEmpty)
        count += 1
      }
    }
    print("radio firmware list: \(pin.images.count) images, \(count) models")
  }

  /// The real download for one model (network; opt in with
  /// AURORA_IPSW_RADIO_TEST=STUB-URL|MACHINE|BOARD). Reports sizes only.
  @Test func oneBoardExtractsFromTheStubImage() async throws {
    guard let spec = ProcessInfo.processInfo.environment["AURORA_IPSW_RADIO_TEST"] else { return }
    let parts = spec.split(separator: "|").map(String.init)
    let source = try RadioFirmwareRestoreImages.source(
      stubSource: try #require(URL(string: parts[0])), machine: parts[1], board: parts[2])
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurora-radio-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: work) }
    let output = work.appendingPathComponent("raw", isDirectory: true)
    let receipt = try await FirmwareExtractor().extract(source.plan, to: output)
    var inputs = [String: Data]()
    for file in receipt.files {
      inputs[String(file.name.dropFirst(RadioFirmwareSource.wifiPath.count + 1))] = try Data(
        contentsOf: output.appendingPathComponent(file.name))
    }
    let outputs = try BroadcomFirmware.wifi(inputs)
    #expect(BroadcomFirmware.carriesWiFi(outputs, board: parts[2]))
    print(
      "radio firmware \(parts[1]) \(parts[2]) from \(source.build): \(receipt.files.count) files, "
        + "\(outputs.count) outputs, \(receipt.authenticatedRangeBytes) range bytes")
  }
}
