import AppKit

/// Tracks the one sheet attached to the installer window.
final class SheetPresenter {
  private(set) var active: NSWindow?
  /// Runs after a sheet has fully closed; it may present the next sheet.
  var onDismiss: (() -> Void)?

  @discardableResult func present(_ sheet: NSWindow, on window: NSWindow?) -> Bool {
    guard let window, active == nil else { return false }
    active = sheet
    window.beginSheet(sheet) { [weak self, weak sheet] _ in
      guard let self, let sheet, self.active === sheet else { return }
      self.active = nil
      self.onDismiss?()
    }
    return true
  }

  func close() {
    guard let sheet = active else { return }
    // endSheet runs the completion synchronously, and onDismiss can present
    // another sheet. Release this one first so that sheet is not forgotten.
    active = nil
    sheet.sheetParent?.endSheet(sheet)
    sheet.orderOut(nil)
    onDismiss?()
  }
}
