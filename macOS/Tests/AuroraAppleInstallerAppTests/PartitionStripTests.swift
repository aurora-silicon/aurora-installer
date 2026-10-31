#if os(macOS)
  import XCTest
  @testable import AuroraAppleInstallerApp

  final class PartitionStripTests: XCTestCase {
    func testWidthsFillTheStripAndKeepSmallPartsVisible() {
      let bytes: [UInt64] = [
        524_288_000, 260_000_000_000, 80_000_000_000, 36_000_000_000, 5_368_709_120,
      ]
      let widths = PartitionStrip.widths(bytes, width: 640)
      let spacing = PartitionStrip.spacing * CGFloat(bytes.count - 1)
      XCTAssertEqual(widths.reduce(0, +) + spacing, 640, accuracy: 0.001)
      XCTAssertEqual(widths[0], PartitionStrip.minimumWidth)
      XCTAssertGreaterThan(widths[4], PartitionStrip.minimumWidth)
      // Larger parts stay in proportion to each other.
      XCTAssertEqual(widths[1] / widths[2], 260 / 80, accuracy: 0.001)
      XCTAssertTrue(PartitionStrip.widths([], width: 640).isEmpty)
    }

    func testCaptionsNeverOverlapOrLeaveTheStrip() {
      let items: [(center: CGFloat, width: CGFloat)] = [
        (300, 120), (320, 80), (330, 110), (600, 150), (630, 60),
      ]
      let centres = CaptionedPartitionStrip.place(items, width: 640)
      var previousEnd = -CGFloat.infinity
      for (centre, item) in zip(centres, items) {
        let left = centre - item.width / 2
        XCTAssertGreaterThanOrEqual(left, previousEnd)
        XCTAssertGreaterThanOrEqual(left, 0)
        XCTAssertLessThanOrEqual(centre + item.width / 2, 640)
        previousEnd = centre + item.width / 2
      }
      // A caption with room stays centred under its part.
      XCTAssertEqual(CaptionedPartitionStrip.place([(200, 60)], width: 640), [200])
    }
  }
#endif
