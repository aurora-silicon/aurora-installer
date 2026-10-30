import AppKit
import AuroraAppleInstallerTrustCore
import SwiftUI

/// KDE Plasma and GNOME show their projects' own screenshots (CC BY 4.0 and
/// CC BY-SA 4.0, credited in About Aurora Installer); the minimal shell is drawn.
struct DesktopPreview: View {
  let desktop: AuroraDesktop

  var body: some View {
    Group {
      switch desktop {
      case .kde: screenshot("KDE-Desktop")
      case .gnome: screenshot("GNOME-Desktop")
      case .minimal: IllustratedDesktop(desktop: desktop)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .aspectRatio(1.6, contentMode: .fit)
    .background(Color(white: 0.08))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func screenshot(_ name: String) -> some View {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      GeometryReader { geometry in
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
      }
    } else {
      IllustratedDesktop(desktop: desktop)
    }
  }
}

private struct IllustratedDesktop: View {
  let desktop: AuroraDesktop

  var body: some View {
    Canvas { context, size in
      var context = context
      context.scaleBy(x: size.width / 320, y: size.height / 200)
      switch desktop {
      case .kde: drawPanelDesktop(in: &context)
      case .gnome: drawTopBarDesktop(in: &context)
      case .minimal: drawShell(in: &context)
      }
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

  private func window(
    _ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat
  ) {
    box(&c, x, y, w, h, Color(white: 0.96), radius: 6)
    box(&c, x, y, w, 16, Color(white: 0.88), radius: 6)
    box(&c, x, y + 10, w, 6, Color(white: 0.88))
    for row in 0..<4 {
      box(
        &c, x + 12, y + 26 + CGFloat(row) * 13, w * (row == 3 ? 0.4 : 0.7), 6,
        Color(white: 0.82), radius: 3)
    }
  }

  /// A desktop with a floating bottom panel: launcher, task icons and a clock.
  private func drawPanelDesktop(in c: inout GraphicsContext) {
    c.fill(
      Path(CGRect(x: 0, y: 0, width: 320, height: 200)),
      with: .linearGradient(
        Gradient(colors: [
          Color(red: 0.11, green: 0.28, blue: 0.55), Color(red: 0.05, green: 0.12, blue: 0.28),
        ]),
        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 320, y: 200)))
    window(&c, 70, 30, 180, 110)
    box(&c, 40, 168, 240, 22, Color(white: 0.12).opacity(0.92), radius: 8)
    symbol(&c, "circle.grid.3x3.fill", 49, 172, size: 12, color: .white.opacity(0.9))
    for index in 0..<4 {
      box(&c, 75 + CGFloat(index) * 20, 173, 12, 12, .white.opacity(0.35), radius: 3)
    }
    label(&c, "10:30", 245, 173, size: 9, color: .white.opacity(0.85))
  }

  /// A desktop with a top bar and a centred dock.
  private func drawTopBarDesktop(in c: inout GraphicsContext) {
    c.fill(
      Path(CGRect(x: 0, y: 0, width: 320, height: 200)),
      with: .linearGradient(
        Gradient(colors: [
          Color(red: 0.20, green: 0.17, blue: 0.32), Color(red: 0.10, green: 0.09, blue: 0.16),
        ]),
        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 320, y: 200)))
    box(&c, 0, 0, 320, 16, .black.opacity(0.85))
    box(&c, 8, 4, 22, 8, .white.opacity(0.7), radius: 4)
    label(&c, "Thu 10:30", 140, 2, size: 8, color: .white.opacity(0.9))
    symbol(&c, "battery.75percent", 296, 2, size: 9, color: .white.opacity(0.85))
    window(&c, 65, 36, 190, 112)
    box(&c, 105, 166, 110, 24, Color(white: 0.18).opacity(0.9), radius: 9)
    for index in 0..<5 {
      box(&c, 113 + CGFloat(index) * 20, 172, 13, 13, .white.opacity(0.4), radius: 4)
    }
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
