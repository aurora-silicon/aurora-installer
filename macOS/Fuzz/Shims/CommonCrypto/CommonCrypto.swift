// SPDX-License-Identifier: MIT
// The names mirror the Apple API this module stands in for.
// swift-format-ignore-file: AlwaysUseLowerCamelCase, TypeNamesShouldBeCapitalized

// Fuzz-only stand-in for CommonCrypto on Linux: the "cipher" copies its input,
// so a fuzzer controls the plaintext that the AEA parser reads next.
#if !os(Linux)
  #error("Fuzz-only stand-in: it must never be built for an Apple platform.")
#endif

public typealias CCCryptorRef = OpaquePointer
public typealias CCCryptorStatus = Int32
public typealias CCOperation = UInt32
public typealias CCMode = UInt32
public typealias CCAlgorithm = UInt32
public typealias CCPadding = UInt32
public typealias CCModeOptions = UInt32
public let kCCSuccess = 0
public let kCCDecrypt = 1
public let kCCModeCTR = 4
public let kCCAlgorithmAES = 0
public let ccNoPadding = 0
public let kCCModeOptionCTR_BE = 2

public func CCCryptorCreateWithMode(
  _ op: CCOperation, _ mode: CCMode, _ alg: CCAlgorithm, _ padding: CCPadding,
  _ iv: UnsafeRawPointer?, _ key: UnsafeRawPointer?, _ keyLength: Int,
  _ tweak: UnsafeRawPointer?, _ tweakLength: Int, _ numRounds: Int32,
  _ options: CCModeOptions, _ cryptorRef: UnsafeMutablePointer<CCCryptorRef?>
) -> CCCryptorStatus {
  cryptorRef.pointee = OpaquePointer(bitPattern: 1)
  return 0
}
public func CCCryptorUpdate(
  _ cryptor: CCCryptorRef?, _ dataIn: UnsafeRawPointer?, _ dataInLength: Int,
  _ dataOut: UnsafeMutableRawPointer?, _ dataOutAvailable: Int,
  _ dataOutMoved: UnsafeMutablePointer<Int>
) -> CCCryptorStatus {
  guard dataInLength <= dataOutAvailable else { return -4301 }
  if dataInLength > 0, let dataIn, let dataOut {
    dataOut.copyMemory(from: dataIn, byteCount: dataInLength)
  }
  dataOutMoved.pointee = dataInLength
  return 0
}
@discardableResult
public func CCCryptorRelease(_ cryptor: CCCryptorRef?) -> CCCryptorStatus { 0 }
