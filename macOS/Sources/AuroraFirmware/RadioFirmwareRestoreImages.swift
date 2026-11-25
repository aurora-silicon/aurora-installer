// SPDX-License-Identifier: MIT
import Foundation

/// Wi-Fi firmware from the System volume of the restore image of the stub
/// the installer installs: radio firmware follows the stub's macOS version.
///
/// A Recovery image may carry only part of a chip's set (26.6.2 Recovery
/// has no usable BCM4388 rev C2 firmware), while the same image's System
/// volume ships every board's. `Resources/radio-firmware/index.json` lists,
/// for each stub restore image of the sealed inspection policy whose root
/// file system the recipes can read, the Wi-Fi board each admitted model's
/// device tree in that image names, and one sealed range recipe per board
/// with that board's files under `usr/share/firmware/wifi`
/// (`macOS/scripts/radio_firmware_recipes.py` writes both from the images).
/// Nothing is read from the running macOS.
public struct RadioFirmwareSource: Sendable {
  public static let wifiPath = "usr/share/firmware/wifi"
  public let build: String
  public let board: String
  public let plan: FirmwareExtractionPlan
}

public enum RadioFirmwareRestoreImages {
  struct Image: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
      case build, url, boards, recipes, sha256
      case sizeBytes = "size_bytes"
    }
    let build: String
    let url: String
    let sizeBytes: Int
    let sha256: String
    /// BuildManifest DeviceClass (`j616sap`) to its Wi-Fi board (`hostomel`).
    let boards: [String: String]
    /// Wi-Fi board to the SHA-256 of its recipe.
    let recipes: [String: String]
  }

  struct Index: Codable, Equatable {
    let schema: Int
    let kind: String
    let images: [Image]
  }

  static func index(_ bytes: Data) throws -> Index {
    let index = try JSONDecoder().decode(Index.self, from: bytes)
    try require(
      index.schema == 1 && index.kind == "aurora-radio-firmware-restore-images"
        && index.images.count <= 64, "Invalid radio firmware restore image list.")
    var urls = Set<String>()
    for image in index.images {
      try require(
        image.build.range(of: #"\A[0-9A-Za-z]{1,16}\z"#, options: .regularExpression) != nil
          && !urls.contains(image.url) && appleRangeURL(image.url) && image.sizeBytes > 0
          && validHash(image.sha256) && image.recipes.values.allSatisfy(validHash)
          && Set(image.boards.values) == Set(image.recipes.keys),
        "Invalid radio firmware restore image entry.")
      urls.insert(image.url)
    }
    return index
  }

  static func embeddedIndex() throws -> Data {
    let bytes = EmbeddedRadioFirmwareRecipes.index
    try require(
      bytes.sha256 == EmbeddedRadioFirmwareRecipes.indexSHA256,
      "Radio firmware restore image list SHA-256 mismatch.")
    return bytes
  }

  /// Whether the stub's restore image is one whose System volume the
  /// installer reads Wi-Fi firmware from. Other stub sources (older plain
  /// disk images, update archives) keep their own Recovery image's firmware.
  public static func covers(stubSource: URL) throws -> Bool {
    try index(embeddedIndex()).images.contains { $0.url == stubSource.absoluteString }
  }

  /// The source of the Wi-Fi firmware for `machine` (`j616s`) whose device
  /// tree names `board` (`hostomel`), from the stub's restore image. An error
  /// when the image is covered but does not name that board for the model.
  public static func source(stubSource: URL, machine: String, board: String) throws
    -> RadioFirmwareSource
  {
    try source(
      stubSource: stubSource, machine: machine, board: board, index: embeddedIndex(),
      recipes: EmbeddedRadioFirmwareRecipes.recipes)
  }

  static func source(
    stubSource: URL, machine: String, board: String, index bytes: Data, recipes: [String: Data]
  ) throws -> RadioFirmwareSource {
    let pin = try Self.index(bytes)
    guard let image = pin.images.first(where: { $0.url == stubSource.absoluteString }) else {
      throw RestoreFailure("No Wi-Fi firmware recipe for this stub's restore image.")
    }
    guard let named = image.boards[machine + "ap"] else {
      throw RestoreFailure(
        "The restore image \(image.build) names no Wi-Fi board for this Mac (\(machine)).")
    }
    try require(
      named == board,
      "This Mac's Wi-Fi board is \(board), but the restore image \(image.build) names \(named).")
    guard let digest = image.recipes[board],
      let recipeBytes = recipes["\(image.build)-\(board).json"]
    else { throw RestoreFailure("No Wi-Fi firmware recipe for \(board) in \(image.build).") }
    try require(recipeBytes.sha256 == digest, "Radio firmware recipe SHA-256 mismatch.")
    let recipe = try strictRecipe(recipeBytes)
    try require(
      recipe.source.url == image.url && recipe.source.sizeBytes == image.sizeBytes
        && recipe.source.sha256 == image.sha256
        && recipe.files.allSatisfy {
          $0.name == $0.source && $0.transform == "identity"
            && $0.name.hasPrefix(RadioFirmwareSource.wifiPath + "/")
        },
      "Radio firmware recipe does not match its image.")
    return RadioFirmwareSource(
      build: image.build, board: board,
      plan: FirmwareExtractionPlan(
        deviceIdentifier: "apple," + machine, recipeSHA256: digest, recipe: recipe))
  }
}
