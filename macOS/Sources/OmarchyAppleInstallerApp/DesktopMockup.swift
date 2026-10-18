import OmarchyAppleInstallerTrustCore
import SwiftUI

/// Deliberately simplified, equally scaled previews. No miniature screenshot text.
struct DesktopMockup: View {
  let desktop: AuroraDesktop

  var body: some View {
    Canvas { context, size in
      var context = context
      context.scaleBy(x: size.width / 320, y: size.height / 200)
      switch desktop {
      case .kde: drawPlasma(in: &context)
      case .gnome: drawGNOME(in: &context)
      case .minimal: drawShell(in: &context)
      }
    }
    .aspectRatio(1.6, contentMode: .fit)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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

  private func wallpaper(_ c: inout GraphicsContext, colors: [Color]) {
    c.fill(
      Path(CGRect(x: 0, y: 0, width: 320, height: 200)),
      with: .linearGradient(
        Gradient(colors: colors), startPoint: .zero,
        endPoint: CGPoint(x: 320, y: 200)))
  }

  private func drawPlasma(in c: inout GraphicsContext) {
    wallpaper(
      &c,
      colors: [
        Color(red: 0.27, green: 0.25, blue: 0.61),
        Color(red: 0.20, green: 0.63, blue: 0.77),
      ])
    var ribbon = Path()
    ribbon.move(to: CGPoint(x: 0, y: 170))
    ribbon.addLine(to: CGPoint(x: 320, y: 35))
    ribbon.addLine(to: CGPoint(x: 320, y: 95))
    ribbon.addLine(to: CGPoint(x: 0, y: 215))
    ribbon.closeSubpath()
    c.fill(ribbon, with: .color(.white.opacity(0.12)))

    // Breeze file manager: a compact title bar, navigation sidebar and folder grid.
    box(&c, 148, 25, 154, 125, Color(white: 0.98), radius: 5)
    box(&c, 148, 25, 154, 20, Color(white: 0.91), radius: 5)
    label(&c, "Files", 158, 30, size: 9, color: .black.opacity(0.7))
    symbol(&c, "minus", 260, 31, size: 8, color: .gray)
    symbol(&c, "square", 275, 31, size: 7, color: .gray)
    symbol(&c, "xmark", 289, 31, size: 7, color: .gray)
    box(&c, 148, 45, 37, 105, Color(white: 0.94))
    for i in 0..<4 { box(&c, 156, CGFloat(57 + i * 17), 22, 4, Color.gray.opacity(0.2), radius: 2) }
    for row in 0..<2 {
      for col in 0..<3 {
        symbol(
          &c, "folder.fill", CGFloat(197 + col * 33), CGFloat(62 + row * 39),
          size: 23, color: Color(red: 0.22, green: 0.65, blue: 0.87))
      }
    }

    // Plasma launcher and floating bottom panel.
    box(&c, 12, 59, 142, 111, Color(white: 0.99).opacity(0.97), radius: 6)
    box(&c, 21, 69, 124, 15, Color(white: 0.91), radius: 4)
    symbol(&c, "magnifyingglass", 27, 72, size: 8, color: .gray)
    label(&c, "Search", 42, 71, size: 9, color: .gray)
    label(&c, "Favorites", 23, 91, size: 10, color: .black.opacity(0.7), weight: .medium)
    let apps: [(String, Color)] = [
      ("globe", .orange), ("folder.fill", .blue),
      ("gearshape.fill", .gray), ("terminal.fill", .indigo),
    ]
    for (i, app) in apps.enumerated() {
      symbol(
        &c, app.0, CGFloat(24 + (i % 2) * 66), CGFloat(110 + (i / 2) * 29),
        size: 20, color: app.1)
    }
    box(&c, 7, 177, 306, 18, Color(white: 0.96).opacity(0.94), radius: 6)
    symbol(&c, "circle.hexagongrid.fill", 15, 181, size: 11, color: .blue)
    for (i, app) in apps.enumerated() {
      symbol(&c, app.0, CGFloat(44 + i * 24), 181, size: 11, color: app.1)
    }
    symbol(&c, "wifi", 262, 182, size: 9, color: .gray)
    label(&c, "12:34", 281, 182, size: 8, color: .black.opacity(0.7))
  }

  private func drawGNOME(in c: inout GraphicsContext) {
    box(&c, 0, 0, 320, 200, Color(white: 0.13))
    box(&c, 0, 0, 320, 15, Color(white: 0.07))
    box(&c, 9, 6, 15, 4, .white.opacity(0.85), radius: 2)
    box(&c, 27, 6, 4, 4, .white.opacity(0.3), radius: 2)
    label(&c, "12:34", 143, 3, size: 8, color: .white.opacity(0.85))
    symbol(&c, "wifi", 281, 4, size: 9, color: .white.opacity(0.8))
    symbol(&c, "battery.100percent", 298, 4, size: 9, color: .white.opacity(0.8))
    box(&c, 84, 24, 152, 18, Color(white: 0.3), radius: 9)
    symbol(&c, "magnifyingglass", 95, 29, size: 8, color: .white.opacity(0.6))

    // Activities overview: workspace, rounded application previews and dash.
    box(&c, 23, 51, 274, 112, Color(red: 0.16, green: 0.38, blue: 0.67), radius: 10)
    box(&c, 306, 51, 28, 112, Color(red: 0.13, green: 0.29, blue: 0.53), radius: 10)
    box(&c, 42, 68, 113, 78, Color(white: 0.97), radius: 8)
    box(&c, 42, 68, 113, 17, Color(white: 0.89), radius: 8)
    symbol(&c, "globe", 50, 73, size: 9, color: .gray)
    box(&c, 59, 95, 76, 7, .blue.opacity(0.15), radius: 3)
    box(&c, 66, 109, 62, 4, .gray.opacity(0.2), radius: 2)
    box(&c, 166, 73, 110, 71, Color(white: 0.97), radius: 8)
    box(&c, 166, 73, 110, 17, Color(white: 0.89), radius: 8)
    for i in 0..<3 {
      symbol(&c, "folder.fill", CGFloat(180 + i * 27), 107, size: 19, color: .blue.opacity(0.75))
    }
    box(&c, 72, 173, 176, 22, Color(white: 0.3), radius: 10)
    let icons = [
      "globe", "calendar", "folder.fill", "doc.text.fill", "gearshape.fill", "square.grid.3x3.fill",
    ]
    let colors: [Color] = [.blue, .purple, .blue, .orange, .gray, .white]
    for i in icons.indices {
      symbol(&c, icons[i], CGFloat(83 + i * 27), 177, size: 14, color: colors[i])
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
