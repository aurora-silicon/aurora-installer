import SwiftUI

/// A compact masthead, an adaptable content column and a persistent action footer.
///
/// Masthead, content and footer share one column: its left edge is the Aurora
/// logo's and its right edge the device identity's, so nothing is inset
/// further and the footer's buttons end where the content does.
struct InstallerPageLayout<Header: View, Content: View, Actions: View>: View {
  static var columnWidth: CGFloat { 640 }
  static var columnMargin: CGFloat { 40 }

  var showsFooter = true
  var contentAlignment: Alignment = .top
  var footerAlignment: Alignment = .trailing
  /// Lets a long page scroll inside the window instead of overflowing it.
  var scrollsContent = false
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: 0) {
      header()
        .inPageColumn()
        .padding(.top, 20)
        .padding(.bottom, 16)
      if scrollsContent {
        ScrollView(.vertical) {
          content()
            .inPageColumn()
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        content()
          .inPageColumn()
          .padding(.vertical, 20)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
      }
      if showsFooter {
        actions()
          .frame(
            maxWidth: Self.columnWidth, minHeight: InstallerTheme.buttonHeight,
            alignment: footerAlignment
          )
          .padding(.horizontal, Self.columnMargin)
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
          .padding(.bottom, 20)
          .background(InstallerTheme.window)
      }
    }
  }
}

extension View {
  /// The page column shared by the masthead, the content and the footer.
  func inPageColumn(alignment: Alignment = .leading) -> some View {
    frame(maxWidth: 640, alignment: alignment)
      .padding(.horizontal, 40)
      .frame(maxWidth: .infinity)
  }
}
