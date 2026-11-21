import AuroraFirmware
import Foundation
import XCTest

/// BCM4388 rev C2 Wi-Fi for the M4 Pro and M4 Max laptops. The fixtures copy
/// the shape of the two real 26.6.2 (25G83) trees: Recovery's C-4388__s-C2
/// holds only aruba NVRAM and regulatory data (its aruba.trx names a missing
/// paradise.trx, so it carries no firmware), while the installed system volume
/// holds every board, with hostomel.trx and mriya.trx naming guam.trx.
final class BroadcomC2WiFiTests: XCTestCase {
  static let firmware = Data("synthetic C2 firmware".utf8)
  /// The M4 Pro and M4 Max laptops' boards (their ADT `wlan` module-instance),
  /// whose radios are BCM4388 rev C2.
  static let boards = ["hostomel", "mriya"]

  /// The 25G83 Recovery image's C2 directory once its dangling links are gone.
  static func recovery25G83() -> (files: [String: Data], links: [String: String]) {
    let directory = "C-4388__s-C2/"
    var files = [
      directory + "P-aruba_M-WLMT_V-u__m-4.9.txt": Data("boardrev=0x1\n".utf8),
      directory + "aruba.clmb": Data("aruba clm".utf8),
      directory + "aruba.txcb": Data("aruba txcap".utf8),
    ]
    var links = [String: String]()
    for sku in BroadcomFirmware.antennaSKUs {
      links[directory + "aruba-" + sku + ".clmb"] = directory + "aruba.clmb"
      links[directory + "P-aruba-" + sku + "_M-WLMT_V-u__m-4.9.txt"] =
        directory + "P-aruba_M-WLMT_V-u__m-4.9.txt"
    }
    files[directory + "aruba.man"] = Data("manifest".utf8)
    return (files, links)
  }

  /// The installed 25G83 system volume's C2 directory for the M4 laptops.
  static func installedSystem(
    boards: [String] = ["hostomel", "mriya"]
  ) -> (files: [String: Data], links: [String: String]) {
    let directory = "C-4388__s-C2/"
    var files = [directory + "guam.trx": firmware]
    var links = [String: String]()
    for board in boards {
      // Each board ships NVRAM for two radio module vendors, AMKOR and USI.
      for vendor in ["a", "u"] {
        let nvram = directory + "P-" + board + "_M-WLMT_V-" + vendor + "__m-4.9.txt"
        files[nvram] = Data("boardrev=0x\(board.count)\nvendor=\(vendor)\n".utf8)
        for sku in BroadcomFirmware.antennaSKUs {
          links[directory + "P-" + board + "-" + sku + "_M-WLMT_V-" + vendor + "__m-4.9.txt"] =
            nvram
        }
      }
      files[directory + board + ".clmb"] = Data((board + " clm").utf8)
      files[directory + board + ".txcb"] = Data((board + " txcap").utf8)
      links[directory + board + ".trx"] = directory + "guam.trx"
      for sku in BroadcomFirmware.antennaSKUs {
        links[directory + board + "-" + sku + ".trx"] = directory + "guam.trx"
        links[directory + board + "-" + sku + ".clmb"] = directory + board + ".clmb"
      }
    }
    return (files, links)
  }

  func testRecovery25G83CannotBringUpAnyM4ProOrMaxBoard() throws {
    let recovery = Self.recovery25G83()
    let outputs = try BroadcomFirmware.wifi(recovery.files, links: recovery.links)
    XCTAssertFalse(outputs.keys.contains { $0.hasSuffix(".bin") }, outputs.keys.description)
    for board in Self.boards {
      let missing = BroadcomFirmware.missingWiFi(outputs, chip: "4388c2", board: board)
      XCTAssertTrue(missing.contains("brcm/brcmfmac4388c2-pcie.apple," + board + ".bin"), board)
      XCTAssertFalse(BroadcomFirmware.carriesWiFi(outputs, board: board), board)
      XCTAssertEqual(BroadcomFirmware.wifiSource(board: board, system: outputs), .recovery)
      // A package of this Recovery alone lacks the board's Wi-Fi.
      XCTAssertEqual(
        BroadcomFirmware.missingRadios(wifi: outputs, bluetooth: [:], board: board).first,
        "brcm/brcmfmac*-pcie.apple," + board + ".bin")
    }
  }

  func testInstalledSystemPackageIsCompleteForEveryM4ProAndMaxBoard() throws {
    let system = Self.installedSystem()
    let outputs = try BroadcomFirmware.wifi(system.files, links: system.links)
    for board in Self.boards {
      XCTAssertEqual(BroadcomFirmware.missingWiFi(outputs, chip: "4388c2", board: board), [])
      XCTAssertEqual(BroadcomFirmware.wifiChips(outputs, board: board), ["4388c2"])
      XCTAssertEqual(outputs["brcm/brcmfmac4388c2-pcie.apple," + board + ".bin"], Self.firmware)
      XCTAssertEqual(BroadcomFirmware.wifiSource(board: board, system: outputs), .system)
    }
    // The C2 directory is converted like any other; nothing in it is skipped.
    XCTAssertNotNil(outputs["brcm/brcmfmac4388c2-pcie.apple,hostomel.clm_blob"])
    XCTAssertNotNil(outputs["brcm/brcmfmac4388c2-pcie.apple,hostomel-WLMT-a.txt"])
    XCTAssertNotNil(outputs["brcm/brcmfmac4388c2-pcie.apple,hostomel-WLMT-u.txt"])
    XCTAssertNotNil(outputs["brcm/brcmfmac4388c2-pcie.apple,hostomel.txcap_blob"])
  }

  func testSourceChoiceFallsBackOnlyWhenTheSystemLacksTheBoard() throws {
    let system = Self.installedSystem(boards: ["mriya"])
    let outputs = try BroadcomFirmware.wifi(system.files, links: system.links)
    XCTAssertEqual(BroadcomFirmware.wifiSource(board: "mriya", system: outputs), .system)
    XCTAssertEqual(BroadcomFirmware.wifiSource(board: "hostomel", system: outputs), .recovery)
    XCTAssertEqual(BroadcomFirmware.wifiSource(board: nil, system: outputs), .recovery)
    XCTAssertEqual(BroadcomFirmware.wifiSource(board: "mriya", system: nil), .recovery)
    // A board name is matched whole: "hostomel" is not "hostomelx".
    XCTAssertFalse(
      BroadcomFirmware.carriesWiFi(
        ["brcm/brcmfmac4388c2-pcie.apple,hostomelx.bin": Data([1])], board: "hostomel"))
  }

  func testConformanceNamesEachMissingKindPerSKU() throws {
    let system = Self.installedSystem(boards: ["hostomel"])
    let outputs = try BroadcomFirmware.wifi(system.files, links: system.links)
    func missing(_ outputs: [String: Data]) -> [String] {
      BroadcomFirmware.missingWiFi(outputs, chip: "4388c2", board: "hostomel")
    }
    XCTAssertEqual(missing(outputs), [])
    let noRegulatory = outputs.filter { !$0.key.hasSuffix(".clm_blob") }
    XCTAssertTrue(
      missing(noRegulatory).contains("brcm/brcmfmac4388c2-pcie.apple,hostomel.clm_blob"))
    XCTAssertTrue(
      missing(noRegulatory).contains("brcm/brcmfmac4388c2-pcie.apple,hostomel-X3.clm_blob"))
    let noNVRAM = outputs.filter { !$0.key.hasSuffix(".txt") }
    XCTAssertTrue(missing(noNVRAM).contains("brcm/brcmfmac4388c2-pcie.apple,hostomel-X3.txt"))
    // NVRAM for one antenna SKU does not cover the others.
    var oneSKU = noNVRAM
    oneSKU["brcm/brcmfmac4388c2-pcie.apple,hostomel-X3-WLMT-u.txt"] = Data("a=b\n".utf8)
    XCTAssertEqual(
      missing(oneSKU),
      ["", "-ID", "-X0", "-X2"].map { "brcm/brcmfmac4388c2-pcie.apple,hostomel" + $0 + ".txt" })
    // An empty file is not firmware.
    var empty = outputs
    empty["brcm/brcmfmac4388c2-pcie.apple,hostomel.bin"] = Data()
    XCTAssertTrue(missing(empty).contains("brcm/brcmfmac4388c2-pcie.apple,hostomel.bin"))
  }

  func testBluetoothConformanceNeedsFirmwareAndPatchTable() throws {
    let inputs = [
      "BCM4388C2_23.5.224.1467_PCIE_macOS_Willamette_Hostomel_CLPC_3ANT_OS_USI_20251203.bin":
        Data([1]),
      "BCM4388C2_EVTv3_PCIE_macOS_Willamette_Hostomel_CLPC_3ANT_OS_USI_K_R_20240919.ptb": Data([2]),
    ]
    let outputs = try BroadcomFirmware.bluetooth(inputs)
    XCTAssertEqual(
      Set(outputs.keys),
      ["brcm/brcmbt4388c2-apple,hostomel-u.bin", "brcm/brcmbt4388c2-apple,hostomel-u.ptb"])
    XCTAssertEqual(
      BroadcomFirmware.missingBluetooth(outputs, chip: "4388c2", board: "hostomel"), [])
    XCTAssertNotEqual(
      BroadcomFirmware.missingBluetooth(outputs, chip: "4388c2", board: "mriya"), [])
    XCTAssertNotEqual(
      BroadcomFirmware.missingBluetooth(
        outputs.filter { $0.key.hasSuffix(".bin") }, chip: "4388c2", board: "hostomel"), [])
  }
}
