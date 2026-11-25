#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation
  import IOKit

  /// Wi-Fi firmware from the System volume of the restore image of the stub
  /// being installed, never from the macOS this Mac runs: radio firmware
  /// follows the stub's version. The stub's Recovery image may lack a board
  /// (26.6.2 (25G83) Recovery has no usable BCM4388 rev C2 firmware for any
  /// M4 Pro or M4 Max board), while the same image's System volume has it.
  enum NativeSystemWiFiFirmware {
    static let prefix = RadioFirmwareSource.wifiPath

    /// This board's Wi-Fi files from the stub restore image's System volume,
    /// extracted by its sealed range recipe under `workingDirectory`. Nil
    /// when the stub comes from an image the recipes do not cover (older
    /// plain disk images, update archives): their own Recovery image is then
    /// the source. A covered image without this board is an error.
    static func stub(
      source: URL, machine: String, board: String, owner: uid_t, workingDirectory: URL
    ) async throws -> NativeFirmwareInputFiles.Snapshot? {
      guard try RadioFirmwareRestoreImages.covers(stubSource: source) else { return nil }
      let radio = try RadioFirmwareRestoreImages.source(
        stubSource: source, machine: machine, board: board)
      let root = try await NativeFirmwarePreparer(expectedOwnerID: owner).extract(
        radio.plan, in: workingDirectory)
      return try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: prefix,
        tree: NativeHandoffFileTree(root, protected: true, owner: owner), owner: owner)
    }

    /// This Mac's Wi-Fi board: the ADT `wlan` node's `module-instance`, the
    /// name aura gives Linux as `brcm,board-type`. Nil when no such node
    /// exists. A hardware fact of this unit (`NativeMachineUnitInputs`); the
    /// restore image must name the same board for the model.
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
