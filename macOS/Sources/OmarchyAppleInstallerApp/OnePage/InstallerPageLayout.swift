import SwiftUI

/// A steady brand position, scrollable content and a persistent action footer.
struct InstallerPageLayout<Header: View, Content: View, Actions: View>: View {
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    GeometryReader { geometry in
      let topInset = 64.0
      let wordmarkHeight = 104.0

      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 0) {
            OmarchyWordmark()
              .frame(width: 104, height: wordmarkHeight)
              .padding(.top, topInset)
              .padding(.bottom, 14)
            Text("Aurora Linux").font(OmarchyTheme.title).padding(.bottom, 12)
            header()
              .frame(minHeight: 24)
              .padding(.bottom, 18)
            content()
              .frame(maxWidth: 560)
              .padding(.bottom, 24)
          }
          .padding(.horizontal, 48)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)

        actions()
          .frame(maxWidth: .infinity, minHeight: OmarchyTheme.buttonHeight)
          .padding(.horizontal, 48)
          .padding(.top, 16)
          .padding(.bottom, 32)
          .background(OmarchyTheme.window)
      }
    }
  }
}
