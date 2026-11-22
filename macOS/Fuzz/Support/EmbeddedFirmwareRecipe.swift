// SPDX-License-Identifier: MIT
// The fuzz build has no sealed recipe; harnesses supply their own inputs.
import Foundation

enum EmbeddedFirmwareRecipe {
  static let sha256 = ""
  static let bytes = Data()
}
