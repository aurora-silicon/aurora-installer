import AppKit

/// Utilities → Remove macOS…: the app's front for `aura remove-macos`. It
/// runs the same preparation and deletion; this only shows the plan, takes the
/// phrase and the owner's password, and reports the outcome. When the
/// installation has no owner of its own yet, it offers the account step.
final class MacOSRemovalFlow {
  private(set) var running = false
  /// Whether Create Recovery Account… can open right now, and opening it.
  var canOpenAccountSetup: () -> Bool = { false }
  var openAccountSetup: () -> Void = {}

  func start() {
    guard !running else { return }
    if RecoveryActions.isPreview {
      inform(
        "Remove macOS (preview)",
        "This preview doesn’t read or change disks. In Recovery, this checks that the recovery account owns this installation, shows exactly what would be deleted and kept, then asks for “\(MacOSRemoval.phrase)” and the account’s password."
      )
      return
    }
    running = true
    InstallerLog.shared.append("Remove macOS: checking this Mac.")
    DispatchQueue.global(qos: .userInitiated).async {
      let prepared = Result { try RecoveryActions.prepareMacOSRemoval() }
      DispatchQueue.main.async { self.review(prepared) }
    }
  }

  private func review(_ prepared: Result<RecoveryActions.MacOSRemovalPreparation, Error>) {
    switch prepared {
    case .failure(let gate as MacOSRemovalNeedsOwner):
      running = false
      InstallerLog.shared.append("Remove macOS: owner step first. " + gate.message)
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "This installation needs its own owner first"
      alert.informativeText = gate.message
      guard gate.canCreate, canOpenAccountSetup() else {
        alert.runModal()
        return
      }
      alert.addButton(withTitle: "Create Recovery Account…")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn { openAccountSetup() }
    case .failure(let error):
      running = false
      InstallerLog.shared.append(
        "Remove macOS refused: " + error.localizedDescription, level: .error)
      inform("macOS can’t be removed", error.localizedDescription)
    case .success(.resumed(let message)):
      running = false
      InstallerLog.shared.append("Remove macOS: " + message)
      inform("Removing macOS", message)
    case .success(.review(let review)):
      confirm(review)
    }
  }

  private func confirm(_ review: RecoveryActions.MacOSRemovalReview) {
    let owner = review.owner.username
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Remove macOS and give Aurora the whole disk?"
    alert.informativeText =
      review.text + "\n\n" + MacOSRemoval.consequences(owner: owner)
    let width: CGFloat = 380
    let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
    let label = NSTextField(
      wrappingLabelWithString: "To continue, type “\(MacOSRemoval.phrase)” and \(owner)’s password."
    )
    label.frame = NSRect(x: 0, y: 64, width: width, height: 32)
    let phrase = NSTextField(frame: NSRect(x: 0, y: 34, width: width, height: 24))
    phrase.placeholderString = MacOSRemoval.phrase
    let secret = NSSecureTextField(frame: NSRect(x: 0, y: 4, width: width, height: 24))
    secret.placeholderString = "Password for \(owner)"
    for view in [label, phrase, secret] { box.addSubview(view) }
    alert.accessoryView = box
    // Cancel is the default button: Return never deletes anything.
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Remove macOS")
    alert.window.initialFirstResponder = phrase
    let response = alert.runModal()
    let typed = phrase.stringValue
    var password = Data(secret.stringValue.utf8)
    phrase.stringValue = ""
    secret.stringValue = ""
    guard response == .alertSecondButtonReturn else {
      password.resetBytes(in: 0..<password.count)
      running = false
      InstallerLog.shared.append("Remove macOS: cancelled. Nothing was changed.")
      return
    }
    InstallerLog.shared.append("Remove macOS: confirmed; deleting.")
    DispatchQueue.global(qos: .userInitiated).async {
      let outcome = Result {
        try RecoveryActions.performMacOSRemoval(review, phrase: typed, password: password)
      }
      password.resetBytes(in: 0..<password.count)
      DispatchQueue.main.async {
        self.running = false
        switch outcome {
        case .success(let message):
          self.inform("macOS was removed", message)
        case .failure(let error):
          InstallerLog.shared.append(
            "Remove macOS failed: " + error.localizedDescription, level: .error)
          self.inform("macOS wasn’t removed", error.localizedDescription)
        }
      }
    }
  }

  private func inform(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }
}
