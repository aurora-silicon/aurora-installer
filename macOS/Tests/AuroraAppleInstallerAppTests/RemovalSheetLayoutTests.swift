#if os(macOS)
  import AppKit
  import SwiftUI
  import XCTest
  @testable import AuroraAppleInstallerApp

  final class RemovalSheetLayoutTests: XCTestCase {
    struct Placement {
      let name: String
      let visibleFrame: CGRect
      let window: CGRect

      var cap: CGFloat {
        RemovalSheetLayout.heightCap(
          parentFrame: window, titleBarHeight: 28, visibleFrame: visibleFrame)
      }
    }

    // 900 and 800 point tall windows filling the visible frame, and the
    // installer's default 780x600 window centred on a 14" MacBook Pro.
    static let placements = [
      Placement(
        name: "14in", visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 900),
        window: CGRect(x: 0, y: 0, width: 1512, height: 900)),
      Placement(
        name: "13in", visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 800),
        window: CGRect(x: 0, y: 0, width: 1470, height: 800)),
      Placement(
        name: "14in-centred", visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
        window: CGRect(x: 366, y: 172.5, width: 780, height: 600)),
    ]

    func testCapReachesFromBelowTheTitleBarToTheBottomOfTheVisibleFrame() {
      let expected: [CGFloat] = [856, 756, 728]
      XCTAssertEqual(Self.placements.map(\.cap), expected)
    }

    func testCapFollowsAWindowPlacedLowerOnTheScreen() {
      let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
      let window = CGRect(x: 300, y: 100, width: 780, height: 600)
      XCTAssertEqual(
        RemovalSheetLayout.heightCap(
          parentFrame: window, titleBarHeight: 28, visibleFrame: visibleFrame),
        700 - 28 - 16)
    }

    func testCapUsesTheParentScreensOrigin() {
      let visibleFrame = CGRect(x: 1512, y: -300, width: 1920, height: 1050)
      let window = CGRect(x: 1600, y: 200, width: 780, height: 500)
      XCTAssertEqual(
        RemovalSheetLayout.heightCap(
          parentFrame: window, titleBarHeight: 28, visibleFrame: visibleFrame),
        700 - 28 - -300 - 16)
    }

    func testCapNeverExceedsTheVisibleFrameOrDropsBelowTheMinimum() {
      let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
      let aboveScreen = CGRect(x: 0, y: 500, width: 780, height: 900)
      XCTAssertEqual(
        RemovalSheetLayout.heightCap(
          parentFrame: aboveScreen, titleBarHeight: 0, visibleFrame: visibleFrame),
        945 - 16)
      let nearBottom = CGRect(x: 0, y: 0, width: 780, height: 200)
      XCTAssertEqual(
        RemovalSheetLayout.heightCap(
          parentFrame: nearBottom, titleBarHeight: 28, visibleFrame: visibleFrame),
        RemovalSheetLayout.minimumHeightCap)
      let tinyScreen = CGRect(x: 0, y: 0, width: 800, height: 300)
      XCTAssertEqual(
        RemovalSheetLayout.heightCap(
          parentFrame: tinyScreen, titleBarHeight: 28, visibleFrame: tinyScreen), 300)
    }

    func testBodyTakesItsContentHeightUntilTheFooterReachesTheCap() {
      XCTAssertEqual(RemovalSheetLayout.bodyHeight(content: 300, footer: 200, cap: 756), 300)
      XCTAssertEqual(RemovalSheetLayout.bodyHeight(content: 900, footer: 200, cap: 756), 556)
      XCTAssertEqual(RemovalSheetLayout.bodyHeight(content: 900, footer: 800, cap: 756), 0)
    }
  }

  #if DEBUG
    @MainActor
    final class RemovalSheetRenderingTests: XCTestCase {
      @MainActor private final class Hosted {
        let window = NSWindow(
          contentRect: CGRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.borderless],
          backing: .buffered, defer: false)
        var view: NSView?
        var controls: [String: CGRect] = [:]
        var size: CGSize { view?.fittingSize ?? .zero }
      }

      private func host(
        _ scenario: RemovalPreviewScenario, cap: CGFloat, showsAccountFields: Bool = false,
        showsApproval: Bool = true
      ) -> Hosted {
        let hosted = Hosted()
        hosted.window.isReleasedWhenClosed = false
        hosted.window.appearance = NSAppearance(named: .aqua)
        let view = NSHostingView(
          rootView: AuroraRemovalSheet(
            previewScenario: scenario, heightCap: cap, showsAccountFields: showsAccountFields,
            showsApproval: showsApproval,
            onControlFrame: { [weak hosted] id, frame in hosted?.controls[id] = frame }
          )
          .environment(\.colorScheme, .light))
        hosted.view = view
        hosted.window.contentView = view
        var previous = CGSize.zero
        for _ in 0..<20 {
          view.layoutSubtreeIfNeeded()
          RunLoop.main.run(until: Date().addingTimeInterval(0.02))
          let size = view.fittingSize
          hosted.window.setContentSize(size)
          view.layoutSubtreeIfNeeded()
          if size == previous { break }
          previous = size
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return hosted
      }

      @discardableResult
      private func assertFits(
        _ scenario: RemovalPreviewScenario, cap: CGFloat, name: String, showsAccountFields: Bool,
        file: StaticString = #filePath, line: UInt = #line
      ) throws -> CGSize {
        let hosted = host(scenario, cap: cap, showsAccountFields: showsAccountFields)
        defer { hosted.window.close() }
        let label = "\(scenario) \(name) accountFields=\(showsAccountFields)"
        let size = hosted.size
        XCTAssertGreaterThan(size.height, 200, label, file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, cap, label, file: file, line: line)
        XCTAssertEqual(hosted.view?.frame.size, size, label, file: file, line: line)
        let bounds = CGRect(origin: .zero, size: size)
        for identifier in ["removal-confirmation", "remove-aurora"] {
          let control = try XCTUnwrap(
            hosted.controls[identifier], "\(label): \(identifier) not laid out", file: file,
            line: line)
          XCTAssertFalse(control.isEmpty, "\(label): \(identifier)", file: file, line: line)
          XCTAssertTrue(
            bounds.contains(control), "\(label): \(identifier) \(control) outside \(bounds)",
            file: file, line: line)
        }
        if scenario != .asahi, !showsAccountFields || scenario == .success {
          let fields = showsAccountFields ? "-account" : ""
          try savePreview(hosted, name: "\(scenario)\(fields)-\(name)")
        }
        return size
      }

      private func savePreview(_ hosted: Hosted, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AURORA_REMOVAL_PREVIEW_DIR"],
          !directory.isEmpty, let view = hosted.view
        else { return }
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: directory).appendingPathComponent("removal-\(name).png")
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
      }

      func testRemovalSheetFitsA14InchAnd13InchScreen() throws {
        for scenario in [RemovalPreviewScenario.success, .asahi, .freeSpace, .startupDisk] {
          for placement in RemovalSheetLayoutTests.placements {
            for showsAccountFields in [false, true] {
              try assertFits(
                scenario, cap: placement.cap, name: placement.name,
                showsAccountFields: showsAccountFields)
            }
          }
        }
      }

      func testCompactReviewHasCompleteScopeBeforeSeparateApproval() throws {
        let review = host(.success, cap: 580, showsAccountFields: true, showsApproval: false)
        defer { review.window.close() }
        XCTAssertLessThanOrEqual(review.size.height, 580)
        XCTAssertNotNil(review.controls["removal-deletions"])
        XCTAssertNotNil(review.controls["removal-kept"])
        XCTAssertNotNil(review.controls["removal-continue"])
        XCTAssertNil(review.controls["remove-aurora"])
        XCTAssertNil(review.controls["removal-confirmation"])
        let bounds = CGRect(origin: .zero, size: review.size)
        for identifier in ["removal-deletions", "removal-kept", "removal-continue"] {
          let frame = try XCTUnwrap(review.controls[identifier])
          XCTAssertTrue(bounds.contains(frame), "\(identifier): \(frame) outside \(bounds)")
        }
        let continueFrame = try XCTUnwrap(review.controls["removal-continue"])
        XCTAssertGreaterThanOrEqual(continueFrame.height, 28)
        let approval = host(.success, cap: 580, showsAccountFields: true)
        defer { approval.window.close() }
        XCTAssertNil(approval.controls["removal-deletions"])
        XCTAssertNil(approval.controls["removal-continue"])
        XCTAssertNotNil(approval.controls["remove-aurora"])
        XCTAssertNotNil(approval.controls["removal-confirmation"])
        try savePreview(review, name: "compact-review")
        try savePreview(approval, name: "separate-approval")
      }
    }
  #endif
#endif
