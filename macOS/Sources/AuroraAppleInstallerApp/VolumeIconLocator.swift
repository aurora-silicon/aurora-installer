import AppKit
import AuroraInstallerUXCore
import Foundation
import SwiftUI

/// Finds the icon a mounted volume carries itself. Reading a mounted
/// volume's root needs no privileges; nothing is mounted here.
enum VolumeIconLocator {
  /// Larger files are not an icon worth decoding for a 36-point row.
  static let maximumIconBytes = 8 << 20

  static func iconFile(forVolumeUUID uuid: String) -> URL? {
    let keys: [URLResourceKey] = [.volumeUUIDStringKey]
    guard
      let volumes = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [])
    else { return nil }
    for volume in volumes {
      guard
        let found = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
        found.caseInsensitiveCompare(uuid) == .orderedSame
      else { continue }
      let icon = volume.appendingPathComponent(".VolumeIcon.icns")
      guard let size = try? icon.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size > 0, size <= maximumIconBytes
      else { return nil }
      return icon
    }
    return nil
  }

  /// macOS's own internal-drive icon, read from the system at run time.
  static let internalDrive: NSImage = {
    let path = "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/Internal.icns"
    return NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(for: .volume)
  }()
}

/// A row's icon: the volume's own when it can be read, else the standard
/// internal drive.
struct InstallationIcon: View {
  let icon: DiskLayoutDisplay.RowIcon
  var size: CGFloat = 36

  var body: some View {
    Group {
      switch icon {
      case .auroraVolume:
        AuroraMark()
      case .volumeIcon(let url):
        Image(nsImage: NSImage(contentsOf: url) ?? VolumeIconLocator.internalDrive)
          .resizable().interpolation(.high).scaledToFit()
      case .internalDrive:
        Image(nsImage: VolumeIconLocator.internalDrive)
          .resizable().interpolation(.high).scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
