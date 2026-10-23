// SPDX-License-Identifier: MIT
// Ported from Eryk Wieliczko's macos-firmware-extract (see README.md).
import CryptoKit
import Darwin
import Foundation

public struct RestoreFailure: Error, LocalizedError, Sendable {
  public let message: String
  public let fallback: Bool
  public init(_ message: String, fallback: Bool = false) {
    self.message = message
    self.fallback = fallback
  }
  public var errorDescription: String? { message }
}

func require(_ valid: Bool, _ message: String) throws {
  if !valid { throw RestoreFailure(message) }
}

extension Data {
  func part(_ offset: Int, _ count: Int) throws -> Data {
    try require(offset >= 0 && count >= 0 && offset <= self.count - count, "Truncated input.")
    return subdata(in: offset..<(offset + count))
  }
  func little(_ offset: Int, _ count: Int) throws -> Int {
    let bytes = try part(offset, count)
    var value: UInt64 = 0
    for (index, byte) in bytes.enumerated() { value |= UInt64(byte) << (index * 8) }
    try require(value <= UInt64(Int.max), "Integer exceeds supported bounds.")
    return Int(value)
  }
  func big32(_ offset: Int) throws -> Int {
    try part(offset, 4).reduce(0) { ($0 << 8) | Int($1) }
  }
  var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

func littleBytes(_ value: Int, count: Int) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) })
}
func validHash(_ value: String) -> Bool {
  value.utf8.count == 64
    && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func unhex(_ value: String) throws -> Data {
  try require(validHash(value), "Invalid SHA-256 or MAC.")
  let bytes = Array(value.utf8)
  func digit(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
  return Data(
    stride(from: 0, to: bytes.count, by: 2).map { digit(bytes[$0]) * 16 + digit(bytes[$0 + 1]) })
}
func safeRelative(_ name: String) -> Bool {
  !name.isEmpty && !name.contains(where: { "\\\0\r\n".contains($0) })
    && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
}

func exists(_ path: URL) -> Bool {
  var info = stat()
  return lstat(path.path, &info) == 0 || errno != ENOENT
}

func openRegular(_ path: URL, maximum: Int) throws -> (FileHandle, Int) {
  var before = stat()
  try require(
    lstat(path.path, &before) == 0 && before.st_mode & S_IFMT == S_IFREG,
    "Input must be a regular file.")
  let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  try require(fd >= 0, "Cannot open input.")
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  var after = stat()
  guard
    fstat(fd, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino
      && after.st_mode & S_IFMT == S_IFREG && after.st_size >= 0 && after.st_size <= maximum
  else {
    try? handle.close()
    throw RestoreFailure("Input identity or size changed.")
  }
  return (handle, Int(after.st_size))
}

func readRegular(_ path: URL, maximum: Int) throws -> Data {
  let (file, size) = try openRegular(path, maximum: maximum)
  defer { try? file.close() }
  let data = try file.read(upToCount: maximum + 1) ?? Data()
  try require(data.count == size && data.count <= maximum, "Input size changed.")
  return data
}

func privateDirectory(beside output: URL, prefix: String) throws -> URL {
  var pattern = Array(
    output.deletingLastPathComponent().appendingPathComponent(prefix + "XXXXXX").path.utf8CString)
  let made = pattern.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
  try require(made != nil, "Cannot create private staging directory.")
  return URL(
    fileURLWithPath: String(
      decoding: pattern.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
}
func writePrivate(_ data: Data, to path: URL) throws {
  let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  try require(fd >= 0, "Cannot create private output.")
  let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  defer { try? file.close() }
  try file.write(contentsOf: data)
  try file.synchronize()
}

public func verifyStage1(_ input: URL, digest: String, size: String) throws {
  guard let size = Int(size), size > 2048, size <= 16 * 1024 * 1024, size % 16384 == 0,
    validHash(digest)
  else { throw RestoreFailure("Invalid raw Stage 1 digest, size or alignment.") }
  let data = try readRegular(input, maximum: 16 * 1024 * 1024)
  try require(data.count == size && data.sha256 == digest, "Raw Stage 1 is missing or changed.")
}

func runNative(
  _ executable: String, _ arguments: [String], timeout: TimeInterval = 1800,
  lease: FileHandle? = nil
) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardInput = lease ?? FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.standardError
  try process.run()
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning {
    if Task<Never, Never>.isCancelled || Date() >= deadline {
      process.terminate()
      let grace = Date().addingTimeInterval(2)
      while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw CancellationError()
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  try require(
    process.terminationReason == .exit && process.terminationStatus == 0,
    "Native \(URL(fileURLWithPath: executable).lastPathComponent) failed.")
}
