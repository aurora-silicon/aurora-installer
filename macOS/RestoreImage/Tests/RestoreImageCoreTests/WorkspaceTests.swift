// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import XCTest

@testable import RestoreImageCore

final class WorkspaceTests: XCTestCase {
  func testAbandonedKeyIsRemovedButActiveAndUnknownDirectoriesRemain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output.dmg")
    let active = try RestoreWorkspace(beside: output)
    try writePrivate(Data("active key".utf8), to: active.url.appendingPathComponent("archive.key"))
    let stale = root.appendingPathComponent(".omarchy-restore-Ab1234")
    try FileManager.default.createDirectory(
      at: stale, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try writePrivate(
      Data("omarchy-restore-workspace-v1\n".utf8), to: stale.appendingPathComponent(".workspace"))
    try writePrivate(Data(), to: stale.appendingPathComponent(".lease"))
    try writePrivate(Data("abandoned key".utf8), to: stale.appendingPathComponent("archive.key"))
    let unknown = root.appendingPathComponent(".omarchy-restore-Xy1234")
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
    let link = root.appendingPathComponent(".omarchy-restore-Sy1234")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
    RestoreWorkspace.removeAbandoned(beside: output)
    XCTAssertFalse(exists(stale))
    XCTAssertTrue(exists(active.url.appendingPathComponent("archive.key")))
    XCTAssertTrue(exists(unknown))
    XCTAssertTrue(exists(link))
    withExtendedLifetime(active) {}
  }

  func testDecoderInheritsLeaseAfterParentClosesItsCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output.dmg")
    let stale = root.appendingPathComponent(".omarchy-restore-Ch1234")
    try FileManager.default.createDirectory(
      at: stale, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try writePrivate(
      Data("omarchy-restore-workspace-v1\n".utf8), to: stale.appendingPathComponent(".workspace"))
    let fd = open(
      stale.appendingPathComponent(".lease").path,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw RestoreFailure("Cannot create test lease") }
    let lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    child.standardInput = lease
    try child.run()
    defer {
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    try lease.close()
    RestoreWorkspace.removeAbandoned(beside: output)
    XCTAssertTrue(exists(stale), "A surviving decoder must retain the workspace lease")
    child.terminate()
    child.waitUntilExit()
    RestoreWorkspace.removeAbandoned(beside: output)
    XCTAssertFalse(exists(stale))
  }
}
