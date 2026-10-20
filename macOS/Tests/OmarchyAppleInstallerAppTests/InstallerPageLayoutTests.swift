#if os(macOS)
  import AppKit
  import OmarchyInstallerUXCore
  import SwiftUI
  import XCTest
  @testable import OmarchyAppleInstallerApp

  @MainActor
  final class InstallerPageLayoutTests: XCTestCase {
    private func containsPageScroll(_ view: NSView) -> Bool {
      view is NSScrollView || view.subviews.contains(where: containsPageScroll)
    }

    func testInstallerPageHasNoScrollContainerAtBothSupportedHeights() {
      for height: CGFloat in [580, 680] {
        let root = InstallerPageLayout {
          InstallerMasthead(device: .simulation)
        } content: {
          VStack(spacing: 20) {
            Text("Choose your space")
            DiskBar(macOSBytes: 272_000_000_000, omarchyBytes: 128_000_000_000,
              unallocatedBytes: 48_000_000_000, otherAllocatedBytes: 64_000_000_000)
          }
        } actions: {
          Button("Install Aurora", action: {})
        }
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(x: 0, y: 0, width: 840, height: height)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(containsPageScroll(view))
      }
    }

    func testSizePromptUsesAnExplicitApplyAndPreservesTheExactExistingSize() {
      var input = DiskSizeInput()
      let exact: UInt64 = 128_123_456_789
      input.begin(bytes: exact, minimum: 32_000_000_000, maximum: 192_000_000_000)
      XCTAssertEqual(input.text, "128")
      XCTAssertEqual(input.requestedBytes, exact)
      input.text = "193"
      XCTAssertNil(input.requestedBytes)
      XCTAssertNotNil(input.validationMessage)
      input.cancel()
      XCTAssertFalse(input.isEditing)
      XCTAssertEqual(input.text, "128")
    }
  }
#endif
