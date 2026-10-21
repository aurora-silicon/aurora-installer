import AppKit

final class RecoveryPrimaryButton: NSButton {
  override var isEnabled: Bool {
    didSet { bezelColor = isEnabled ? AuroraTheme.accent : AuroraTheme.card }
  }

  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return NSSize(
      width: max(92, size.width + 30), height: max(AuroraTheme.buttonHeight, size.height))
  }

  init(title: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    bezelStyle = .rounded
    font = AuroraTheme.button
    contentTintColor = AuroraTheme.accentText
    bezelColor = AuroraTheme.accent
    isBordered = true
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: AuroraTheme.buttonHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}

final class RecoverySecondaryButton: NSButton {
  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return NSSize(width: size.width + 26, height: max(AuroraTheme.buttonHeight, size.height))
  }

  init(title: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    bezelStyle = .rounded
    font = AuroraTheme.control
    contentTintColor = AuroraTheme.text
    isBordered = true
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: AuroraTheme.buttonHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}

final class RecoveryTextButton: NSButton {
  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return NSSize(width: size.width + 24, height: max(AuroraTheme.buttonHeight, size.height))
  }

  init(title: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    font = AuroraTheme.control
    contentTintColor = AuroraTheme.secondaryText
    isBordered = false
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: AuroraTheme.buttonHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}
