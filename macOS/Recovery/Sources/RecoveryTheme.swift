import AppKit

final class RecoveryPrimaryButton: NSButton {
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
    controlSize = .large
    isBordered = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
}

/// The same native large rounded button as RecoveryPrimaryButton, without
/// the default (Return) emphasis, so paired buttons match in shape and size.
final class RecoverySecondaryButton: NSButton {
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
    controlSize = .large
    isBordered = true
    translatesAutoresizingMaskIntoConstraints = false
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
