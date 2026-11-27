import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI
import UniformTypeIdentifiers

/// Window → Installer Log (⌘L), modelled on the Installer Log of Apple's
/// Install macOS app: a level filter, a search field, Save…, and the lines in
/// monospaced text that follows new lines unless the person scrolls up.
enum InstallerLogWindow {
  static let id = "installer-log"
  static let title = "Installer Log"
}

/// The Window menu item that opens the log.
struct InstallerLogMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(InstallerLogWindow.title) { openWindow(id: InstallerLogWindow.id) }
      .keyboardShortcut("l", modifiers: .command)
  }
}

struct InstallerLogView: View {
  static let filterKey = "InstallerLogFilter"
  let store: InstallerLogStore
  /// Remembered between launches unless a render fixes it.
  private let remembersFilter: Bool
  @State private var filter: InstallerLogFilter
  @State private var search: String

  init(store: InstallerLogStore, filter: InstallerLogFilter? = nil, search: String = "") {
    self.store = store
    remembersFilter = filter == nil
    _filter = State(
      initialValue: filter
        ?? UserDefaults.standard.string(forKey: Self.filterKey).flatMap(InstallerLogFilter.init)
        ?? .errorsAndProgress)
    _search = State(initialValue: search)
  }

  var body: some View {
    let visible = InstallerLogFormat.visible(store.entries, filter: filter, search: search)
    VStack(spacing: 0) {
      HStack(spacing: Space.s) {
        Picker("Show", selection: $filter) {
          ForEach(InstallerLogFilter.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        Spacer(minLength: 12)
        InstallerLogSearchField(text: $search)
          .frame(width: 220)
        Button("Save…") { save(visible) }
          .disabled(visible.isEmpty)
      }
      .padding(.horizontal, Space.m)
      .padding(.vertical, Space.s)
      Divider()
      InstallerLogTextView(entries: visible, search: search)
      Divider()
      footer(visible: visible.count)
    }
    .frame(minWidth: 620, minHeight: 320)
    .onChange(of: filter) {
      if remembersFilter { UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey) }
    }
  }

  private func footer(visible: Int) -> some View {
    HStack(spacing: Space.s) {
      Text(
        visible == store.entries.count
          ? "\(store.entries.count) lines" : "\(visible) of \(store.entries.count) lines")
      if !store.running.isEmpty {
        Divider().frame(height: 12)
        ProgressView().controlSize(.mini)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(Self.running(store.running, now: context.date))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 8)
      if let url = store.file?.url {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Text(InstallerLogRedactor.line(url.path))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .buttonStyle(.link)
        .help("Show the log file in Finder")
      }
    }
    .font(InstallerTheme.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, Space.m)
    .padding(.vertical, Space.xs)
  }

  /// `Running: helper/diskutil#21 (4 s), aurora.img.zst (1 min 02 s)`.
  static func running(_ entries: [InstallerLogEntry], now: Date) -> String {
    let items = entries.map { entry -> String in
      let name = (entry.activity ?? entry.source).replacingOccurrences(of: "download:", with: "")
      let seconds = Int(max(0, now.timeIntervalSince(entry.time)))
      let age =
        seconds < 60 ? "\(seconds) s" : String(format: "%d min %02d s", seconds / 60, seconds % 60)
      return "\(name) (\(age))"
    }
    return "Running: " + items.joined(separator: ", ")
  }

  private func save(_ entries: [InstallerLogEntry]) {
    let panel = NSSavePanel()
    let stamp = InstallerLogFormat.timestamp(Date()).prefix(16)
      .replacingOccurrences(of: ":", with: ".")
    panel.nameFieldStringValue = "\(InstallerProductIdentity.appName) Log \(stamp).log"
    panel.allowedContentTypes = [UTType.log, .plainText]
    panel.canCreateDirectories = true
    let text = InstallerLogFormat.document(entries, filter: filter, search: search)
    let write: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try Data(text.utf8).write(to: url, options: .atomic)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: write)
    } else {
      write(panel.runModal())
    }
  }
}

/// AppKit's search field, as Apple's Installer Log has.
private struct InstallerLogSearchField: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search"
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.controlSize = .regular
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    let text: Binding<String>
    init(text: Binding<String>) { self.text = text }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}

/// The lines, in a read-only text view: selectable, copyable with ⌘C, and
/// appended to in place while the filter and search stay the same. It
/// follows new lines while scrolled to the end.
struct InstallerLogTextView: NSViewRepresentable {
  let entries: [InstallerLogEntry]
  let search: String
  static let sourceWidth = 16

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    if let text = scroll.documentView as? NSTextView {
      text.isEditable = false
      text.isSelectable = true
      text.isRichText = false
      text.drawsBackground = true
      text.backgroundColor = .textBackgroundColor
      text.textContainerInset = NSSize(width: 6, height: 6)
      text.usesFindBar = true
      text.isIncrementalSearchingEnabled = true
      text.textContainer?.widthTracksTextView = true
      text.setAccessibilityLabel(InstallerLogWindow.title)
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else {
      return
    }
    let coordinator = context.coordinator
    let followsEnd = coordinator.shown.isEmpty || Self.isAtEnd(scroll)
    let previous = coordinator.shown
    let appends =
      coordinator.search == search && !previous.isEmpty && previous.count <= entries.count
      && entries[previous.count - 1].sequence == previous.last
      && entries.first?.sequence == previous.first
    if appends {
      guard previous.count < entries.count else { return }
      storage.append(Self.text(entries[previous.count...], search: search))
    } else {
      storage.setAttributedString(Self.text(entries[...], search: search))
    }
    coordinator.shown = entries.map(\.sequence)
    coordinator.search = search
    if followsEnd { text.scrollToEndOfDocument(nil) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var shown: [UInt64] = []
    var search = ""
  }

  static func isAtEnd(_ scroll: NSScrollView) -> Bool {
    guard let document = scroll.documentView else { return true }
    let visible = scroll.contentView.documentVisibleRect
    return visible.maxY >= document.bounds.maxY - 24
  }

  static func text(_ entries: ArraySlice<InstallerLogEntry>, search: String) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    let paragraph = NSMutableParagraphStyle()
    // Wrapped lines start under the message, not under the time.
    let indent = (String(repeating: " ", count: 14 + sourceWidth + 1) as NSString)
      .size(withAttributes: [.font: font]).width
    paragraph.headIndent = indent
    paragraph.lineBreakMode = .byWordWrapping
    let result = NSMutableAttributedString()
    let needle = search.trimmingCharacters(in: .whitespaces)
    for entry in entries {
      let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
      let time = InstallerLogFormat.clock(entry.time) + "  "
      let source =
        entry.source.count >= sourceWidth
        ? entry.source + " "
        : entry.source.padding(toLength: sourceWidth, withPad: " ", startingAt: 0)
          + " "
      var line = base
      line[.foregroundColor] = NSColor.secondaryLabelColor
      result.append(NSAttributedString(string: time, attributes: line))
      line[.foregroundColor] = NSColor.tertiaryLabelColor
      let sourceStart = result.length
      result.append(NSAttributedString(string: source, attributes: line))
      highlight(needle, in: entry.source, at: sourceStart, of: result)
      var message = base
      switch entry.level {
      case .error:
        message[.foregroundColor] = NSColor.systemRed
        message[.font] = bold
      case .progress:
        message[.foregroundColor] = NSColor.labelColor
      case .debug:
        message[.foregroundColor] = NSColor.secondaryLabelColor
      }
      let start = result.length
      result.append(NSAttributedString(string: entry.message + "\n", attributes: message))
      highlight(needle, in: entry.message, at: start, of: result)
    }
    return result
  }

  /// Marks each match of `needle` in `text`, which starts at `offset`.
  private static func highlight(
    _ needle: String, in text: String, at offset: Int, of result: NSMutableAttributedString
  ) {
    guard !needle.isEmpty else { return }
    let body = text as NSString
    var range = body.range(of: needle, options: .caseInsensitive)
    while range.location != NSNotFound {
      result.addAttribute(
        .backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.55),
        range: NSRange(location: offset + range.location, length: range.length))
      let next = range.location + range.length
      range = body.range(
        of: needle, options: .caseInsensitive,
        range: NSRange(location: next, length: body.length - next))
    }
  }
}
