import OmarchyAppleInstallerTrustCore
import SwiftUI

/// Downscaled project screenshots; the minimal shell keeps its illustrated preview.
struct DesktopPreview: View {
  let desktop: AuroraDesktop

  var body: some View {
    Group {
      switch desktop {
      case .kde: BrandImage("KDE-Desktop")
      case .gnome: BrandImage("GNOME-Desktop")
      case .minimal: ShellPreview()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .aspectRatio(1.6, contentMode: .fit)
    .background(Color(white: 0.08))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ShellPreview: View {
  var body: some View {
    Canvas { context, size in
      var context = context
      context.scaleBy(x: size.width / 320, y: size.height / 200)
      drawShell(in: &context)
    }
    .aspectRatio(1.6, contentMode: .fit)
  }

  private func box(
    _ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat,
    _ w: CGFloat, _ h: CGFloat, _ color: Color, radius: CGFloat = 0
  ) {
    c.fill(
      Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius),
      with: .color(color))
  }

  private func label(
    _ c: inout GraphicsContext, _ text: String, _ x: CGFloat, _ y: CGFloat,
    size: CGFloat, color: Color, weight: Font.Weight = .regular
  ) {
    c.draw(
      Text(text).font(.system(size: size, weight: weight)).foregroundColor(color),
      at: CGPoint(x: x, y: y), anchor: .topLeading)
  }

  private func symbol(
    _ c: inout GraphicsContext, _ name: String, _ x: CGFloat,
    _ y: CGFloat, size: CGFloat, color: Color
  ) {
    c.draw(
      Text(Image(systemName: name)).font(.system(size: size)).foregroundColor(color),
      at: CGPoint(x: x, y: y), anchor: .topLeading)
  }

  private func drawShell(in c: inout GraphicsContext) {
    box(&c, 0, 0, 320, 200, Color(red: 0.07, green: 0.08, blue: 0.11))
    box(&c, 0, 0, 320, 28, .white.opacity(0.035))
    symbol(&c, "terminal", 14, 8, size: 12, color: .white.opacity(0.5))
    label(&c, "aurora", 43, 7, size: 11, color: .white.opacity(0.5))
    label(&c, "Welcome to Aurora", 20, 53, size: 16, color: .white.opacity(0.95), weight: .medium)
    label(&c, "Linux · aarch64", 20, 82, size: 12, color: .white.opacity(0.42))
    label(&c, "~", 20, 119, size: 16, color: .cyan)
    label(&c, "❯", 40, 118, size: 16, color: .green)
    box(&c, 60, 119, 7, 17, .white.opacity(0.9), radius: 1)
  }
}
