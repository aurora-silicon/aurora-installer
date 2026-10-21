import AppKit

/// The same Aurora mark and name used by the macOS installer.
final class AuroraWordmark: NSView {
  private let mark = NSImageView()
  private let name = NSTextField(labelWithString: "Aurora")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    if let url = Bundle.main.url(forResource: "AuroraLogo", withExtension: "png") {
      mark.image = NSImage(contentsOf: url)
    }
    mark.imageScaling = .scaleProportionallyUpOrDown
    mark.translatesAutoresizingMaskIntoConstraints = false
    name.font = NSFont.systemFont(ofSize: 38, weight: .semibold)
    name.textColor = AuroraTheme.text
    name.translatesAutoresizingMaskIntoConstraints = false
    let row = NSStackView(views: [mark, name])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 14
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      mark.widthAnchor.constraint(equalToConstant: 84),
      mark.heightAnchor.constraint(equalToConstant: 84),
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityLabel("Aurora")
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}
