import AppKit

/// A fixed-size, keyboard-modal AppKit sheet styled like the Recovery window.
final class RecoverySheet: NSPanel {
  init(
    title: String, message: String, width: CGFloat, height: CGFloat,
    body: NSView, bodyHeight: CGFloat, buttons: [NSButton]
  ) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled], backing: .buffered, defer: false)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    isReleasedWhenClosed = false
    appearance = NSAppearance(named: .darkAqua)
    backgroundColor = AuroraTheme.card
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(kind)?.isHidden = true
    }

    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.wantsLayer = true
    root.layer?.backgroundColor = AuroraTheme.darkCGColor(AuroraTheme.card)
    root.layer?.cornerRadius = AuroraTheme.cardRadius
    contentView = root

    let heading = NSTextField(labelWithString: title)
    heading.font = AuroraTheme.mono(19, .semibold)
    heading.textColor = AuroraTheme.text
    heading.lineBreakMode = .byWordWrapping
    heading.maximumNumberOfLines = 0
    heading.preferredMaxLayoutWidth = width - 56
    heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    heading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(heading)

    let explanation = NSTextField(labelWithString: message)
    explanation.font = AuroraTheme.control
    explanation.textColor = AuroraTheme.secondaryText
    explanation.lineBreakMode = .byWordWrapping
    explanation.maximumNumberOfLines = 0
    explanation.preferredMaxLayoutWidth = width - 56
    explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    explanation.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(explanation)

    body.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(body)

    let actions = NSStackView()
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 12
    actions.translatesAutoresizingMaskIntoConstraints = false
    for button in buttons { actions.addArrangedSubview(button) }
    root.addSubview(actions)

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
      explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
      explanation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
      explanation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
      body.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 18),
      body.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      body.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -56),
      body.heightAnchor.constraint(equalToConstant: bodyHeight),
      actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
      actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
      body.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -14),
    ])
  }
}
