#if os(macOS)
  import Darwin
  import Foundation
  import IOKit

  /// Wi-Fi and Bluetooth firmware from the macOS this Mac runs. Its sealed
  /// system volume ships every board's firmware, and macOS runs it, while the
  /// stub's Recovery image may be older (macOS 13.5 on many installs) or lack
  /// a board: 26.6.2 (25G83) Recovery has no usable BCM4388 rev C2 Wi-Fi
  /// firmware for any M4 Pro or M4 Max board.
  enum NativeSystemRadioFirmware {
    static let prefix = "usr/share/firmware"

    /// One radio's tree of the running system (`wifi` or `bluetooth`), read
    /// only from a read-only volume.
    static func live(owner: uid_t, directory: String) throws -> NativeFirmwareInputFiles.Snapshot {
      let root = URL(fileURLWithPath: "/", isDirectory: true)
      let path = prefix + "/" + directory
      let tree = try NativeHandoffFileTree(
        root, protected: true, owner: owner, readOnlyVolume: true)
      let descriptor = try tree.fileDescriptor(path)
      defer { close(descriptor) }
      guard NativeHandoffFileTree.isReadOnly(descriptor) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      return try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: path, tree: tree, owner: owner)
    }

    /// This Mac's radio board: the ADT `wlan` node's `module-instance`, which
    /// matches the kernel device tree's `brcm,board-type` and the board name
    /// both Broadcom drivers load their firmware by. Nil when no such node
    /// exists (including N1/Centauri Macs).
    static func board() throws -> String? {
      var iterator: io_iterator_t = 0
      guard
        IORegistryCreateIterator(
          kIOMainPortDefault, kIODeviceTreePlane, IOOptionBits(kIORegistryIterateRecursively),
          &iterator) == KERN_SUCCESS
      else { return nil }
      defer { IOObjectRelease(iterator) }
      var count = 0
      while true {
        try Task.checkCancellation()
        let entry = IOIteratorNext(iterator)
        if entry == 0 { return nil }
        defer { IOObjectRelease(entry) }
        count += 1
        guard count <= 65_536 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(entry, kIODeviceTreePlane, &name) == KERN_SUCCESS,
          String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == "wlan",
          let bytes = IORegistryEntryCreateCFProperty(
            entry, "module-instance" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { continue }
        return admitted(bytes)
      }
    }

    /// A board name is a short lowercase word, as every Apple board is.
    static func admitted(_ bytes: Data) -> String? {
      let value = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      guard value.range(of: #"\A[a-z][a-z0-9]{0,31}\z"#, options: .regularExpression) != nil
      else { return nil }
      return value
    }
  }
#endif
