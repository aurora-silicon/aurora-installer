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
      .padding(.top, 20)
      .padding(.bottom, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header()
          content()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .frame(maxHeight: .infinity)
      actions()
        .frame(maxWidth: .infinity, minHeight: OmarchyTheme.buttonHeight)
        .padding(.horizontal, 40)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(OmarchyTheme.window)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
  }
}
