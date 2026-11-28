// SPDX-License-Identifier: MIT
// Shared harness plumbing: libFuzzer calls each target on its own thread, so
// an async reader runs to completion on the cooperative pool while the
// fuzzer thread waits for it.
import Dispatch
import Foundation

@testable import AuroraFirmware

final class FuzzResult<Value>: @unchecked Sendable {
  var value: Value?
}

func fuzzBlocking<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) -> Value? {
  let done = DispatchSemaphore(value: 0)
  let result = FuzzResult<Value>()
  Task {
    result.value = try? await body()
    done.signal()
  }
  done.wait()
  return result.value
}

func fuzzData(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Data {
  Data(bytes: bytes, count: count)
}

/// An archive held in memory, read the way the HTTP range reader is: exact
/// ranges inside its declared size.
struct FuzzMemorySource: FirmwareRangeReading {
  let bytes: Data
  var sizeBytes: Int { bytes.count }
  func read(offset: Int, count: Int) async throws -> Data { try bytes.part(offset, count) }
}

/// Reads little-endian fields from the front of a fuzz input.
struct FuzzFields {
  var data: Data
  var cursor = 0
  init(_ data: Data) { self.data = data }
  mutating func int(_ width: Int) -> Int {
    var value = 0
    for index in 0..<width where cursor + index < data.count {
      value |= Int(data[data.startIndex + cursor + index]) << (index * 8)
    }
    cursor += width
    return value
  }
  mutating func bytes(_ count: Int) -> Data {
    let start = min(cursor, data.count)
    let end = min(start + max(0, count), data.count)
    cursor = end
    return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
  }
  mutating func rest() -> Data { bytes(data.count) }
}

/// With FUZZ_DEBUG set, a harness reports why a reader refused an input, to
/// check that seeds reach the code they are meant for.
let fuzzDebug = ProcessInfo.processInfo.environment["FUZZ_DEBUG"] != nil
func fuzzNote(_ stage: String, _ error: any Error) {
  if fuzzDebug { FileHandle.standardError.write(Data("\(stage): \(error)\n".utf8)) }
}
