// SPDX-License-Identifier: MIT
// The names mirror the Apple API this module stands in for.
// swift-format-ignore-file: AlwaysUseLowerCamelCase, TypeNamesShouldBeCapitalized

// Fuzz-only stand-in for the Darwin module on Linux: Glibc plus the few
// Darwin-only calls the compiled sources name. None of them runs in a harness.
#if !os(Linux)
  #error("Fuzz-only stand-in: it must never be built for an Apple platform.")
#endif
@_exported import Glibc

public let RENAME_EXCL: Int32 = 4
public let RENAME_SWAP: Int32 = 2
public func renamex_np(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>, _ flags: UInt32)
  -> Int32
{
  errno = ENOSYS
  return -1
}
public func renameatx_np(
  _ fromFD: Int32, _ from: UnsafePointer<CChar>, _ toFD: Int32, _ to: UnsafePointer<CChar>,
  _ flags: UInt32
) -> Int32 {
  errno = ENOSYS
  return -1
}
