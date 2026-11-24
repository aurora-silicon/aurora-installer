// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import AuroraFirmware

struct SpeakerTuningRestoreImagesTests {
  private static let tunings = SpeakerTuningSource.tuningsPath

  /// A structurally valid recipe for a made-up AID: the J700 fixture's
  /// ranges with its files renamed to a tuning folder, a volume
  /// configuration and the component. No Apple data.
  private func recipe(aid: UInt32, rename: Bool = true) throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: "j700-25G83-ranges", withExtension: "json", subdirectory: "Fixtures"))
    var document = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var files = try #require(document["files"] as? [[String: Any]])
    if rename {
      for index in files.indices {
        let name: String
        switch index {
        case 0: name = SpeakerTuningSource.componentPath
        case 1: name = Self.tunings + "/Config/AID\(aid).plist"
        default: name = Self.tunings + "/AID\(aid)/DSP/Strips/file\(index).austrip"
        }
        files[index]["name"] = name
        files[index]["source"] = name
      }
    }
    document["files"] = files
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
  }

  private func source(_ recipe: Data) throws -> [String: Any] {
    let document = try #require(try JSONSerialization.jsonObject(with: recipe) as? [String: Any])
    return try #require(document["source"] as? [String: Any])
  }

  private func index(_ images: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "schema": 1, "kind": "aurora-speaker-tuning-restore-images", "release": "99.9",
        "images": images,
      ] as [String: Any], options: [.sortedKeys])
  }

  private func image(
    _ build: String, recipe: Data, boards: [String: UInt32], recipes: [String: String]
  ) throws -> [String: Any] {
    let source = try source(recipe)
    return [
      "build": build, "url": source["url"]!, "size_bytes": source["size_bytes"]!,
      "sha256": source["sha256"]!, "boards": boards, "recipes": recipes,
    ]
  }

  @Test func theFirstImageCarryingTheBoardIsUsed() throws {
    let first = try recipe(aid: 97)
    let second = try recipe(aid: 98)
    let pin = try index([
      image("00A001", recipe: first, boards: ["j999ap": 97], recipes: ["97": first.sha256]),
      image(
        "00A002", recipe: second, boards: ["j998ap": 98, "j999ap": 98],
        recipes: ["98": second.sha256]),
    ])
    let recipes = ["00A001-AID97.json": first, "00A002-AID98.json": second]
    let one = try SpeakerTuningRestoreImages.source(
      board: "j999", acousticID: 97, index: pin, recipes: recipes)
    #expect(one.build == "00A001" && one.release == "99.9" && one.acousticID == 97)
    #expect(one.plan.recipeSHA256 == first.sha256)
    #expect(one.plan.deviceIdentifier == "apple,j999")
    #expect(one.componentSHA256 != nil)
    let two = try SpeakerTuningRestoreImages.source(
      board: "j998", acousticID: 98, index: pin, recipes: recipes)
    #expect(two.build == "00A002" && two.plan.recipeSHA256 == second.sha256)
    // The first image that carries the board decides: no other image's AID.
    #expect(throws: (any Error).self) {
      try SpeakerTuningRestoreImages.source(
        board: "j999", acousticID: 98, index: pin, recipes: recipes)
    }
  }

  @Test func everyMismatchIsAnErrorWithoutFallback() throws {
    let good = try recipe(aid: 97)
    let recipes = ["00A001-AID97.json": good]
    let pin = try index([
      image("00A001", recipe: good, boards: ["j999ap": 97], recipes: ["97": good.sha256])
    ])
    // A board no image carries, another AID, an invalid board name.
    for (board, aid) in [("j100", UInt32(97)), ("j999", 96), ("J999", 97), ("j999ap/x", 97)] {
      #expect(throws: (any Error).self) {
        try SpeakerTuningRestoreImages.source(
          board: board, acousticID: aid, index: pin, recipes: recipes)
      }
    }
    // A missing or changed recipe.
    #expect(throws: (any Error).self) {
      try SpeakerTuningRestoreImages.source(
        board: "j999", acousticID: 97, index: pin, recipes: [:])
    }
    var changed = good
    changed.append(0x20)
    #expect(throws: (any Error).self) {
      try SpeakerTuningRestoreImages.source(
        board: "j999", acousticID: 97, index: pin, recipes: ["00A001-AID97.json": changed])
    }
    // A recipe of other files (the unchanged J700 recipe).
    let other = try recipe(aid: 97, rename: false)
    let otherPin = try index([
      image("00A001", recipe: other, boards: ["j999ap": 97], recipes: ["97": other.sha256])
    ])
    #expect(throws: (any Error).self) {
      try SpeakerTuningRestoreImages.source(
        board: "j999", acousticID: 97, index: otherPin, recipes: ["00A001-AID97.json": other])
    }
    // An image whose recipes do not cover its boards' AIDs.
    let partial = try index([
      image(
        "00A001", recipe: good, boards: ["j999ap": 97, "j998ap": 98],
        recipes: [
          "97": good.sha256
        ])
    ])
    #expect(throws: (any Error).self) {
      try SpeakerTuningRestoreImages.source(
        board: "j999", acousticID: 97, index: partial, recipes: recipes)
    }
  }

  /// APFS type 9, seen on small tuning plists: the file uncompressed in the
  /// attribute after a 0xcc marker byte. Any other layout is refused.
  @Test func uncompressedAttributeStorage() throws {
    let plain = Data("synthetic small file".utf8)
    func attr(_ size: Int) -> Data {
      Data("fpmc".utf8) + littleBytes(9, count: 4) + littleBytes(size, count: 8)
    }
    let marker = Data([0xcc])
    let size = plain.count
    let good: Data = attr(size) + marker + plain
    #expect(try decompressStorage([good]) == plain)
    let noMarker: Data = attr(size) + plain + Data([0])
    let trailing: Data = good + Data([0])
    let short: Data = attr(size + 1) + marker + plain
    let refused: [[Data]] = [[noMarker], [trailing], [short], [good, Data([0])], [attr(size)]]
    for storage in refused {
      #expect(throws: (any Error).self) { try decompressStorage(storage) }
    }
  }

  /// The compiled-in pin: macOS 27.2, and every board it names resolves to
  /// a recipe that passes admission, with the tuning folder, the volume
  /// configuration and the AudioDSP component.
  @Test func theCompiledInPinResolvesEveryBoard() throws {
    #expect(try SpeakerTuningRestoreImages.release == "27.2")
    let pin = try SpeakerTuningRestoreImages.index(SpeakerTuningRestoreImages.embeddedIndex())
    #expect(pin.images.map(\.build) == ["26B123", "26B8125"])
    var seen = Set<String>()
    var boards = 0
    for image in pin.images {
      for (deviceClass, aid) in image.boards where !seen.contains(deviceClass) {
        seen.insert(deviceClass)
        let source = try SpeakerTuningRestoreImages.source(
          board: String(deviceClass.dropLast(2)), acousticID: aid)
        #expect(source.build == image.build)
        #expect(source.plan.sourceURL.absoluteString == image.url)
        #expect(source.componentSHA256 != nil)
        boards += 1
      }
    }
    #expect(boards > 0)
    print("speaker tuning pin: \(boards) boards, \(pin.images.count) images")
  }

  /// The real download for one board (network; opt in with
  /// AURORA_IPSW_SPEAKER_TEST=BOARD:AID, e.g. j713:37). Reports sizes only.
  @Test func oneBoardExtractsFromThePinnedImage() async throws {
    guard let spec = ProcessInfo.processInfo.environment["AURORA_IPSW_SPEAKER_TEST"] else {
      return
    }
    let parts = spec.split(separator: ":")
    let aid = try #require(UInt32(parts.last ?? ""))
    let source = try SpeakerTuningRestoreImages.source(board: String(parts[0]), acousticID: aid)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurora-speaker-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: work) }
    let output = work.appendingPathComponent("raw", isDirectory: true)
    let receipt = try await FirmwareExtractor().extract(source.plan, to: output)
    #expect(receipt.files.count == source.plan.outputs.count)
    _ = try FirmwareExtractor().verify(source.plan, at: output)
    print(
      "speaker tuning \(spec) from \(source.build): \(receipt.files.count) files, "
        + "\(receipt.authenticatedRangeBytes) range bytes")
  }
}
