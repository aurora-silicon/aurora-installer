import SwiftUI

/// A compact masthead, an adaptable content column and a persistent action footer.
struct InstallerPageLayout<Header: View, Content: View, Actions: View>: View {
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        OmarchyWordmark().frame(width: 36, height: 36)
        Text("Aurora Linux").font(.system(size: 20, weight: .semibold))
        Spacer()
      }
      .frame(maxWidth: 640)
      .padding(.horizontal, 40)
      .padding(.top, 28)
      .padding(.bottom, 20)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          header()
          content()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .frame(maxHeight: .infinity)
      actions()
        .frame(maxWidth: .infinity, minHeight: OmarchyTheme.buttonHeight)
        .padding(.horizontal, 40)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(OmarchyTheme.window)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
  }
}
