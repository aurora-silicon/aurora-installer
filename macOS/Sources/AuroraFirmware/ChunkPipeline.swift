// SPDX-License-Identifier: MIT
import Foundation

/// Hands every chunk, in order, to each of its stages. Each stage runs on a
/// queue of its own, so while the producer makes one chunk, a stage can
/// handle an earlier one and another stage an earlier one still.
///
/// At most `depth` chunks wait for any one stage. A producer that gets ahead
/// waits for room without holding a thread. The first failure in a stage
/// drops every chunk still waiting, so no stage handles anything after it,
/// and the next `submit` or `finish` reports it. Neither `finish` nor
/// `cancel` returns while a stage is still handling a chunk, so the state a
/// stage touches is the caller's again once they return.
final class ChunkPipeline: @unchecked Sendable {
  typealias Handler = @Sendable (Data) throws -> Void

  private struct Stage {
    let queue: DispatchQueue
    let handle: Handler
    var waiting: [Data] = []
    var running = false
  }

  private struct Waiter {
    let ready: () -> Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private let lock = NSLock()
  private let depth: Int
  private var stages: [Stage]
  private var failure: (any Error)?
  private var waiter: Waiter?

  init(depth: Int = 4, stages handlers: [Handler]) {
    precondition(depth > 0 && !handlers.isEmpty)
    self.depth = depth
    stages = handlers.enumerated().map { index, handle in
      Stage(
        queue: DispatchQueue(
          label: "org.aurorasilicon.chunk-pipeline.stage-\(index)", qos: .userInitiated),
        handle: handle)
    }
  }

  /// Queues `chunk` for every stage once each has room for it.
  func submit(_ chunk: Data) async throws {
    await wait { self.failure != nil || self.stages.allSatisfy { $0.waiting.count < self.depth } }
    let starting: [(Int, DispatchQueue)] = try lock.withLock {
      if let failure { throw failure }
      var starting = [(Int, DispatchQueue)]()
      for index in stages.indices {
        stages[index].waiting.append(chunk)
        if !stages[index].running {
          stages[index].running = true
          starting.append((index, stages[index].queue))
        }
      }
      return starting
    }
    for (index, queue) in starting {
      queue.async { self.drain(index) }
    }
  }

  /// Returns once every stage has handled every chunk, or throws the first
  /// failure once no stage is still handling a chunk.
  func finish() async throws {
    await wait { self.stages.allSatisfy { !$0.running } }
    if let failure = lock.withLock({ failure }) { throw failure }
  }

  /// Drops the chunks still waiting and returns once no stage is handling one.
  func cancel() async {
    lock.withLock {
      if failure == nil { failure = CancellationError() }
      for index in stages.indices { stages[index].waiting.removeAll() }
    }
    await wait { self.stages.allSatisfy { !$0.running } }
  }

  private func drain(_ index: Int) {
    while true {
      let (next, ready) = lock.withLock { () -> ((Data, Handler)?, Waiter?) in
        guard failure == nil, !stages[index].waiting.isEmpty else {
          stages[index].running = false
          stages[index].waiting.removeAll()
          return (nil, takeReadyWaiter())
        }
        let chunk = stages[index].waiting.removeFirst()
        return ((chunk, stages[index].handle), takeReadyWaiter())
      }
      ready?.continuation.resume()
      guard let (chunk, handle) = next else { return }
      do {
        try handle(chunk)
      } catch {
        lock.withLock {
          if failure == nil { failure = error }
          for stage in stages.indices { stages[stage].waiting.removeAll() }
        }
      }
    }
  }

  /// Suspends until `ready`, which is evaluated under the lock, holds.
  private func wait(until ready: @escaping () -> Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if ready() {
        lock.unlock()
        continuation.resume()
        return
      }
      precondition(waiter == nil, "One producer drives a chunk pipeline.")
      waiter = Waiter(ready: ready, continuation: continuation)
      lock.unlock()
    }
  }

  /// Called with the lock held after the state changed.
  private func takeReadyWaiter() -> Waiter? {
    guard let waiter, waiter.ready() else { return nil }
    self.waiter = nil
    return waiter
  }
}
