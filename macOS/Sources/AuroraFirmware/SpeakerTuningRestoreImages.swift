// SPDX-License-Identifier: MIT
import Foundation

/// The one source of every Mac's per-model speaker tuning: Apple's restore
/// images of the speaker safety stack's pinned macOS release.
///
/// `Resources/speaker-tuning/index.json` is the single record of that pin:
/// the release, each restore image's build, URL, size and SHA-256 in order,
/// and for each image the boards its BuildManifest carries with the
/// `acoustic-id` that board's device tree in the same image names. One
/// sealed range recipe per image and AID selects the tuning folder, the
/// selection files and the AudioDSP component from the image's System
/// volume (`macOS/scripts/speaker_tuning_recipes.py` writes both from the
/// images themselves). The installer compiles all of it in.
///
/// The first image that carries the Mac's board is used, whatever macOS the
/// Mac runs. There is no other source and no fallback: not the running
/// macOS, not another build. A board no pinned image carries, an AID the
/// image does not name for that board, or a recipe that fails its pins is
/// an error, and the Mac gets no speaker tuning (Linux keeps its speakers
/// muted).
public struct SpeakerTuningSource: Sendable {
  /// The pinned macOS release, e.g. 27.2.
  public let release: String
  /// The restore image's build, e.g. 26B123: the bundle's `macos_build`.
  public let build: String
  public let acousticID: UInt32
  /// The authenticated partial download of the image's files.
  public let plan: FirmwareExtractionPlan

  /// Where the extracted files are, relative to the plan's output: the
  /// image's System volume layout.
  public static let tuningsPath = "System/Library/Audio/Tunings"
  public static let componentPath =
    "System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"

  /// SHA-256 of the image's AudioDSP component, as the recipe pins it.
  public var componentSHA256: String? {
    plan.outputs.first { $0.name == Self.componentPath }?.sha256
  }
}

public enum SpeakerTuningRestoreImages {
  struct Image: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
      case build, url, boards, recipes, sha256
      case sizeBytes = "size_bytes"
    }
    let build: String
    let url: String
    let sizeBytes: Int
    let sha256: String
    /// BuildManifest DeviceClass (`j713ap`) to the acoustic ID the image's
    /// own device tree for that board names.
    let boards: [String: UInt32]
    /// Acoustic ID (decimal) to the SHA-256 of its recipe.
    let recipes: [String: String]
  }

  struct Index: Codable, Equatable {
    let schema: Int
    let kind: String
    let release: String
    let images: [Image]
  }

  static func recipeName(build: String, acousticID: UInt32) -> String {
    "\(build)-AID\(acousticID).json"
  }

  static func index(_ bytes: Data) throws -> Index {
    let index = try JSONDecoder().decode(Index.self, from: bytes)
    try require(
      index.schema == 1 && index.kind == "aurora-speaker-tuning-restore-images"
        && !index.release.isEmpty && (1...8).contains(index.images.count),
      "Invalid speaker tuning restore image pin.")
    var builds = Set<String>()
    for image in index.images {
      try require(
        image.build.range(of: #"\A[0-9A-Za-z]{1,16}\z"#, options: .regularExpression) != nil
          && !builds.contains(image.build) && appleRangeURL(image.url) && image.sizeBytes > 0
          && validHash(image.sha256) && image.recipes.values.allSatisfy(validHash)
          && Set(image.boards.values.map { String($0) }) == Set(image.recipes.keys),
        "Invalid speaker tuning restore image entry.")
      builds.insert(image.build)
    }
    return index
  }

  /// The compiled-in pin.
  public static var release: String {
    get throws { try index(embeddedIndex()).release }
  }

  static func embeddedIndex() throws -> Data {
    let bytes = EmbeddedSpeakerTuningRecipes.index
    try require(
      bytes.sha256 == EmbeddedSpeakerTuningRecipes.indexSHA256,
      "Speaker tuning restore image pin SHA-256 mismatch.")
    return bytes
  }

  /// The source for a Mac, from its board (`j713`, from the device tree
  /// root's `target-type`) and its `acoustic-id`.
  public static func source(board: String, acousticID: UInt32) throws -> SpeakerTuningSource {
    try source(
      board: board, acousticID: acousticID, index: embeddedIndex(),
      recipes: EmbeddedSpeakerTuningRecipes.recipes)
  }

  static func source(
    board: String, acousticID: UInt32, index bytes: Data, recipes: [String: Data]
  ) throws -> SpeakerTuningSource {
    let pin = try Self.index(bytes)
    try require(
      board.range(of: #"\A[a-z0-9]{1,8}\z"#, options: .regularExpression) != nil,
      "Invalid board name.")
    guard let image = pin.images.first(where: { $0.boards[board + "ap"] != nil }) else {
      throw RestoreFailure(
        "No pinned macOS \(pin.release) restore image carries this Mac's board (\(board)).")
    }
    let named = image.boards[board + "ap"]!
    try require(
      named == acousticID,
      "This Mac reports acoustic-id \(acousticID), but the macOS \(pin.release) restore image "
        + "\(image.build) names \(named) for its board (\(board)).")
    let name = recipeName(build: image.build, acousticID: acousticID)
    guard let digest = image.recipes[String(acousticID)], let recipeBytes = recipes[name] else {
      throw RestoreFailure("No speaker tuning recipe for AID\(acousticID) in \(image.build).")
    }
    try require(recipeBytes.sha256 == digest, "Speaker tuning recipe SHA-256 mismatch.")
    let recipe = try strictRecipe(recipeBytes)
    try require(
      recipe.source.url == image.url && recipe.source.sizeBytes == image.sizeBytes
        && recipe.source.sha256 == image.sha256,
      "Speaker tuning recipe names another restore image.")
    let names = Set(recipe.files.map(\.name))
    let folder = SpeakerTuningSource.tuningsPath + "/AID\(acousticID)/"
    try require(
      names.contains(SpeakerTuningSource.componentPath)
        && names.contains(SpeakerTuningSource.tuningsPath + "/Config/AID\(acousticID).plist")
        && names.contains(where: { $0.hasPrefix(folder) })
        && recipe.files.allSatisfy {
          $0.name == $0.source && $0.transform == "identity"
            && ($0.name == SpeakerTuningSource.componentPath
              || $0.name.hasPrefix(SpeakerTuningSource.tuningsPath + "/"))
        },
      "Speaker tuning recipe holds other files.")
    return SpeakerTuningSource(
      release: pin.release, build: image.build, acousticID: acousticID,
      plan: FirmwareExtractionPlan(
        deviceIdentifier: "apple," + board, recipeSHA256: digest, recipe: recipe))
  }
}
