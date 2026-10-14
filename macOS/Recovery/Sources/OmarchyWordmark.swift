import AppKit
import SwiftUI

struct OmarchyWordmark: View {
  var body: some View {
    if let url = Bundle.main.url(forResource: "AuroraLogo", withExtension: "png"),
      let image = NSImage(contentsOf: url) {
      Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        .accessibilityLabel("Aurora Silicon")
    }
  }
}
