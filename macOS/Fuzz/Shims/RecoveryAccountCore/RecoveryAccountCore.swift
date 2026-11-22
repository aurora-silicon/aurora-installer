// SPDX-License-Identifier: MIT
// Fuzz-only stand-in for the parts of RecoveryAccountCore the Recovery
// template reader names. A harness never publishes, so nothing here runs
// against a real tree.
import Foundation

#if !os(Linux)
  #error("Fuzz-only stand-in: it must never be built for an Apple platform.")
#endif

public enum RecoveryFileTransaction {
  public static func flushTree(_ path: URL) throws {}
  public static func flushDirectory(_ path: URL) throws {}
}
