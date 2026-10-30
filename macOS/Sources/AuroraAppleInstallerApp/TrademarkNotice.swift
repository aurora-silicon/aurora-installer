import AppKit

/// Names this installer uses factually to describe what it installs and where.
/// Fedora's wording is the notice its trademark guidelines require; GNOME's and
/// KDE's follow the attribution those projects publish.
enum TrademarkNotice {
  static let text = [
    "Aurora is an independent project. It is not provided, supported or endorsed by "
      + "the Fedora Project, Red Hat, Arch Linux, Arch Linux ARM, the NixOS project, "
      + "KDE e.V., the GNOME Foundation or Apple.",
    "Fedora® is a registered trademark of Red Hat, Inc., or its subsidiaries in the "
      + "United States and other countries. Official Fedora is available at fedoraproject.org.",
    "KDE® is a registered trademark of KDE e.V. GNOME is a registered trademark or "
      + "trademark of the GNOME Foundation in the United States or other countries.",
    "Apple, Mac, MacBook and macOS are trademarks of Apple Inc., "
      + "registered in the U.S. and other countries.",
    "KDE Plasma screenshot by the KDE Community, CC BY 4.0. GNOME screenshot by the GNOME "
      + "Project, CC BY-SA 4.0; the resized copy is shared under the same licence.",
    "Other names are trademarks of their respective owners.",
  ]

  static var credits: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.paragraphSpacing = 6
    return NSAttributedString(
      string: text.joined(separator: "\n"),
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ])
  }
}
