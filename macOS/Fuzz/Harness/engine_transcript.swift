// SPDX-License-Identifier: MIT
// The engine transcript (JSON lines) the installer reads back from an
// installation journal on disk.
import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzEngineTranscript(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
  do { _ = try EngineTranscriptDecoder().decode(fuzzData(bytes, count)) } catch {
    fuzzNote("transcript", error)
  }
  return 0
}
