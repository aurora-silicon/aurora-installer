import AuroraFirmware
import Foundation
import XCTest

/// The board-keyed radio checks. The ADT names a Mac's radio board (the
/// `wlan` node's `module-instance`) but not its chip revision, so each check
/// works from the board alone.
final class BroadcomBoardRadioTests: XCTestCase {
  func testBluetoothSourceFollowsTheBoardsFirmwareOnTheSystem() throws {
    let system = try BroadcomFirmware.bluetooth([
      "BCM4378B1_FinalV0_PCIE_macOS_Shikoku_OS_MUR_K_R_20200902.bin": Data([1]),
      "BCM4378B1_FinalV0_PCIE_macOS_Shikoku_OS_MUR_K_R_20200902.ptb": Data([2]),
    ])
    XCTAssertEqual(
      Set(system.keys),
      ["brcm/brcmbt4378b1-apple,shikoku-m.bin", "brcm/brcmbt4378b1-apple,shikoku-m.ptb"])
    XCTAssertTrue(BroadcomFirmware.carriesBluetooth(system, board: "shikoku"))
    XCTAssertEqual(BroadcomFirmware.bluetoothChips(system, board: "shikoku"), ["4378b1"])
    XCTAssertEqual(BroadcomFirmware.bluetoothSource(board: "shikoku", system: system), .system)
    // Another board's firmware, no board, or no readable system leave Recovery.
    XCTAssertEqual(BroadcomFirmware.bluetoothSource(board: "honshu", system: system), .recovery)
    XCTAssertEqual(BroadcomFirmware.bluetoothSource(board: nil, system: system), .recovery)
    XCTAssertEqual(BroadcomFirmware.bluetoothSource(board: "shikoku", system: nil), .recovery)
    // A board is matched whole, with or without a module vendor.
    func carries(_ name: String, _ data: Data = Data([1])) -> Bool {
      BroadcomFirmware.carriesBluetooth([name: data], board: "shikoku")
    }
    XCTAssertFalse(carries("brcm/brcmbt4378b1-apple,shikokux-m.bin"))
    XCTAssertTrue(carries("brcm/brcmbt4378b1-apple,shikoku.bin"))
    // A patch table alone, an empty file or a Wi-Fi name is not Bluetooth firmware.
    XCTAssertFalse(carries("brcm/brcmbt4378b1-apple,shikoku-m.ptb"))
    XCTAssertFalse(carries("brcm/brcmbt4378b1-apple,shikoku-m.bin", Data()))
    XCTAssertFalse(carries("brcm/brcmfmac4378b1-pcie.apple,shikoku.bin"))
  }

  /// tokara as macOS ships it: Wi-Fi for BCM4388 rev B0 and C0, and rev B0
  /// Bluetooth firmware without a patch table next to complete rev C0.
  func testOneCompleteRevisionPerRadioBringsTheBoardUp() throws {
    var wifi = [String: Data]()
    for chip in ["4388b0", "4388c0"] {
      let stem = "brcm/brcmfmac" + chip + "-pcie.apple,tokara"
      wifi[stem + ".bin"] = Data((chip + " firmware").utf8)
      wifi[stem + ".clm_blob"] = Data((chip + " regulatory").utf8)
      wifi[stem + "-WLMT-u.txt"] = Data("boardrev=0x1\n".utf8)
    }
    let bluetooth = [
      "brcm/brcmbt4388b0-apple,tokara-u.bin": Data([1]),
      "brcm/brcmbt4388c0-apple,tokara-u.bin": Data([2]),
      "brcm/brcmbt4388c0-apple,tokara-u.ptb": Data([3]),
    ]
    XCTAssertEqual(BroadcomFirmware.wifiChips(wifi, board: "tokara"), ["4388b0", "4388c0"])
    XCTAssertEqual(
      BroadcomFirmware.bluetoothChips(bluetooth, board: "tokara"), ["4388b0", "4388c0"])
    XCTAssertEqual(
      BroadcomFirmware.missingRadios(wifi: wifi, bluetooth: bluetooth, board: "tokara"), [])
    // Without a complete revision, the first revision's gaps are named.
    XCTAssertEqual(
      BroadcomFirmware.missingRadios(
        wifi: wifi, bluetooth: bluetooth.filter { $0.key.contains("4388b0") }, board: "tokara"),
      ["brcm/brcmbt4388b0-apple,tokara-u.bin", "brcm/brcmbt4388b0-apple,tokara-u.ptb"])
    XCTAssertEqual(
      BroadcomFirmware.missingRadios(
        wifi: wifi.filter { !$0.key.hasSuffix(".clm_blob") }, bluetooth: bluetooth,
        board: "tokara"
      ).first, "brcm/brcmfmac4388b0-pcie.apple,tokara.clm_blob")
    // A board neither radio has.
    XCTAssertEqual(
      BroadcomFirmware.missingRadios(wifi: wifi, bluetooth: bluetooth, board: "amami"),
      ["brcm/brcmfmac*-pcie.apple,amami.bin", "brcm/brcmbt*-apple,amami-*.bin"])
  }
}
