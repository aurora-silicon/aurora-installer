import Foundation
import XCTest

@testable import AuroraFirmware

final class ChunkPipelineTests: XCTestCase {
  private struct StageFailure: Error, Equatable {}

  /// Counts chunks submitted and handled, and the most ever in between.
  private final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    private var handled: [Int] = []
    private(set) var mostAhead = 0

    func submit() { lock.withLock { submitted += 1 } }
    func handle(_ value: Int) {
      lock.withLock { handled.append(value) }
    }
    func checkAhead() {
      lock.withLock { mostAhead = max(mostAhead, submitted - handled.count) }
    }
    var values: [Int] { lock.withLock { handled } }
  }

  private static func chunk(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
  }

  private static func value(_ chunk: Data) -> Int {
    Int(chunk.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
  }

  func testEveryStageSeesEveryChunkInOrderAndAProducerStaysWithinTheDepth() async throws {
    let fast = Ledger()
    let slow = Ledger()
    let pipeline = ChunkPipeline(
      depth: 3,
      stages: [
        { fast.handle(Self.value($0)) },
        {
          usleep(500)
          slow.handle(Self.value($0))
        },
      ])
    for index in 0..<200 {
      slow.submit()
      try await pipeline.submit(Self.chunk(index))
      slow.checkAhead()
    }
    try await pipeline.finish()
    XCTAssertEqual(fast.values, Array(0..<200))
    XCTAssertEqual(slow.values, Array(0..<200))
    // Three waiting and one in hand.
    XCTAssertLessThanOrEqual(slow.mostAhead, 4)
  }

  func testAStageFailureStopsEveryStageAndIsReportedOnce() async throws {
    let failing = Ledger()
    let other = Ledger()
    let pipeline = ChunkPipeline(
      depth: 2,
      stages: [
        {
          let value = Self.value($0)
          failing.handle(value)
          if value == 4 { throw StageFailure() }
        },
        { other.handle(Self.value($0)) },
      ])
    var refused = false
    for index in 0..<100 {
      do {
        try await pipeline.submit(Self.chunk(index))
      } catch let error as StageFailure {
        XCTAssertEqual(error, StageFailure())
        refused = true
        break
      }
    }
    do {
      try await pipeline.finish()
      XCTFail("A failed stage finished cleanly.")
    } catch let error as StageFailure {
      XCTAssertEqual(error, StageFailure())
    }
    XCTAssertTrue(refused, "Submitting after the failure was refused.")
    XCTAssertEqual(failing.values, Array(0...4), "Nothing reached the stage after it failed.")
    XCTAssertEqual(other.values, Array(0..<other.values.count))
  }

  func testCancelDropsWaitingChunksAndWaitsForTheOneInHand() async throws {
    final class Gate: @unchecked Sendable {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      private let lock = NSLock()
      private var handled = 0
      private var returned = false
      var handledCount: Int { lock.withLock { handled } }
      var cancelReturned: Bool {
        get { lock.withLock { returned } }
        set { lock.withLock { returned = newValue } }
      }
      func handle() {
        lock.withLock { handled += 1 }
        entered.signal()
        release.wait()
      }
    }
    let gate = Gate()
    let pipeline = ChunkPipeline(depth: 4, stages: [{ _ in gate.handle() }])
    for index in 0..<4 { try await pipeline.submit(Self.chunk(index)) }
    XCTAssertEqual(gate.entered.wait(timeout: .now() + 10), .success)
    let cancelling = Task {
      await pipeline.cancel()
      gate.cancelReturned = true
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(gate.cancelReturned, "Cancel returned while a chunk was in hand.")
    gate.release.signal()
    await cancelling.value
    XCTAssertTrue(gate.cancelReturned)
    XCTAssertEqual(gate.handledCount, 1, "Waiting chunks were dropped.")
    do {
      try await pipeline.submit(Self.chunk(5))
      XCTFail("A cancelled pipeline took another chunk.")
    } catch is CancellationError {}
  }
}
