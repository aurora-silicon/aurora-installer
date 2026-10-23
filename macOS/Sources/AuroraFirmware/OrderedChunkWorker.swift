// SPDX-License-Identifier: MIT
import Foundation

/// Hands chunks, in order, to `work` on a thread of its own, with at most
/// `depth` chunks waiting, so a producer can go on while each chunk is
/// handled. The first failure is reported by the next `submit` or `finish`,
/// and the chunks still waiting are then dropped.
final class OrderedChunkWorker: @unchecked Sendable {
  private let condition = NSCondition()
  private let depth: Int
  private let work: @Sendable (Data) throws -> Void
  private var waiting: [Data] = []
  private var failure: (any Error)?
  private var closed = false
  private var stopped = false

  init(depth: Int = 4, work: @escaping @Sendable (Data) throws -> Void) {
    self.depth = depth
    self.work = work
    let thread = Thread { [self] in run() }
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  func submit(_ bytes: Data) throws {
    condition.lock()
    defer { condition.unlock() }
    while waiting.count >= depth && failure == nil && !closed { condition.wait() }
    if let failure { throw failure }
    guard !closed else { throw CancellationError() }
    waiting.append(bytes)
    condition.broadcast()
  }

  /// Returns once every submitted chunk has been handled.
  func finish() throws {
    condition.lock()
    defer { condition.unlock() }
    closed = true
    condition.broadcast()
    while !stopped { condition.wait() }
    if let failure { throw failure }
  }

  /// Drops the chunks still waiting and returns once the one in hand is done.
  func cancel() {
    condition.lock()
    defer { condition.unlock() }
    waiting.removeAll()
    closed = true
    if failure == nil { failure = CancellationError() }
    condition.broadcast()
    while !stopped { condition.wait() }
  }

  private func run() {
    while true {
      condition.lock()
      while waiting.isEmpty && !closed { condition.wait() }
      guard !waiting.isEmpty, failure == nil else {
        waiting.removeAll()
        stopped = true
        condition.broadcast()
        condition.unlock()
        return
      }
      let bytes = waiting.removeFirst()
      condition.broadcast()
      condition.unlock()
      do {
        try work(bytes)
      } catch {
        condition.lock()
        if failure == nil { failure = error }
        waiting.removeAll()
        condition.broadcast()
        condition.unlock()
      }
    }
  }
}
