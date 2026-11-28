// SPDX-License-Identifier: MIT
// The sealed firmware range recipe's strict JSON reader and validation, then
// the network closure a partial local copy leaves.
import Foundation

@testable import AuroraFirmware

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzRangeRecipe(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  let data = fuzzData(bytes, count)
  guard data.count <= 1024 * 1024, let recipe = try? strictRecipe(data) else { return 0 }
  _ = try? networkRecipe(recipe, preferred: [:])
  if let file = recipe.files.first {
    _ = try? networkRecipe(recipe, preferred: [file.name: Data(count: file.size)])
  }
  return 0
}
