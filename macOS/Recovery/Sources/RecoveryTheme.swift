import AppKit

final class RecoveryPrimaryButton: NSButton {
  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return NSSize(
      width: max(96, size.width + 40), height: max(AuroraTheme.buttonHeight, size.height))
  }

  init(title: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    bezelStyle = .rounded
    font = AuroraTheme.button
    contentTintColor = AuroraTheme.accentText
    wantsLayer = true
    layer?.backgroundColor = AuroraTheme.darkCGColor(AuroraTheme.accent)
    layer?.cornerRadius = AuroraTheme.buttonRadius
    isBordered = false
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: AuroraTheme.buttonHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}

final class RecoverySecondaryButton: NSButton {
  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize
    return NSSize(width: size.width + 32, height: max(AuroraTheme.buttonHeight, size.height))
  }

  init(title: String, target: AnyObject?, action: Selector?) {
    super.init(frame: .zero)
    self.title = title
    self.target = target
    self.action = action
    font = AuroraTheme.control
    contentTintColor = AuroraTheme.secondaryText
    isBordered = false
    wantsLayer = true
    layer?.backgroundColor = AuroraTheme.darkCGColor(AuroraTheme.card)
    layer?.borderColor = AuroraTheme.darkCGColor(AuroraTheme.separator)
    layer?.borderWidth = 1
    layer?.cornerRadius = AuroraTheme.buttonRadius
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
