import AppKit

@main struct Check {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let payload = String(repeating: "0123456789abcdef log line\n", count: 2500)
    precondition(payload.utf8.count < 65536)
    let viewer = LogTextView(text: payload)
    viewer.frame = NSRect(x: 0, y: 0, width: 474, height: 200)
    let window = NSWindow(
      contentRect: viewer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = viewer
    viewer.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let container = viewer.textView.textContainer,
      let manager = viewer.textView.layoutManager
    else { fatalError("native log view not created") }
    let started = Date()
    manager.ensureLayout(for: container)
    let bounds = manager.usedRect(for: container)
    precondition(viewer.displayedText == payload)
    precondition(viewer.textView.isSelectable && !viewer.textView.isEditable)
    precondition(bounds.height > 200 && bounds.width > 0 && bounds.width <= 474)
    viewer.update(text: "replacement\n")
    precondition(viewer.displayedText == "replacement\n")
    print(
      "PASS native selectable log viewer: \(payload.utf8.count) bytes, layout \(bounds.width)x\(bounds.height), layout check \(Date().timeIntervalSince(started))s"
    )
    window.orderOut(nil)
  }
}
