import AppKit

/// A bounded, selectable native log view that preserves the user's scroll position.
final class LogTextView: NSScrollView {
  private let editor: NSTextView

  init(text: String) {
    editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 474, height: 200))
    super.init(frame: .zero)
    hasVerticalScroller = true
    autohidesScrollers = true
    drawsBackground = true
    backgroundColor = AuroraTheme.window
    wantsLayer = true
    layer?.cornerRadius = AuroraTheme.buttonRadius
    layer?.borderColor = AuroraTheme.darkCGColor(AuroraTheme.separator)
    layer?.borderWidth = 1
    editor.isEditable = false
    editor.isSelectable = true
    editor.isRichText = false
    editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    editor.textColor = .textColor
    editor.drawsBackground = false
    editor.textContainerInset = NSSize(width: 12, height: 12)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(
      width: 474, height: CGFloat.greatestFiniteMagnitude)
    documentView = editor
    update(text: text)
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  var displayedText: String { editor.string }
  var textView: NSTextView { editor }

  func update(text: String) {
    guard editor.string != text else { return }
    let atEnd = editor.string.isEmpty || contentView.bounds.maxY >= editor.bounds.maxY - 24
    let selection = editor.selectedRange()
    editor.string = text
    if atEnd {
      editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
    } else {
      let count = editor.string.utf16.count
      let start = min(selection.location, count)
      editor.setSelectedRange(
        NSRange(location: start, length: min(selection.length, count - start)))
    }
  }
}
