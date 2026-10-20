import SwiftUI

/// A compact masthead, an adaptable content column and a persistent action footer.
struct InstallerPageLayout<Header: View, Content: View, Actions: View>: View {
  var showsFooter = true
  var contentAlignment: Alignment = .center
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: 0) {
      header()
        .frame(maxWidth: 640)
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .padding(.bottom, 16)
      content()
        .frame(maxWidth: 640)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
      if showsFooter {
        actions()
          .frame(maxWidth: .infinity, minHeight: OmarchyTheme.buttonHeight)
          .padding(.horizontal, 40)
          .padding(.top, 12)
          .padding(.bottom, 20)
          .background(OmarchyTheme.window)
      }
    }
  }
}
