import Foundation
import Testing

@testable import OmarchyAppleInstallerTrustCore

struct SHA256DigestTests {
  @Test func acceptsExactLowercasePrefixedDigest() throws {
    let value = "sha256:" + String(repeating: "0a", count: 32)
    let digest = try #require(SHA256Digest(rawValue: value))
    #expect(digest.rawValue == value)
    #expect(SHA256Digest(hexadecimal: digest.hexadecimal) == digest)
  }

  @Test func rejectsWrongPrefixLengthAndAlphabet() {
    #expect(SHA256Digest(rawValue: String(repeating: "0", count: 64)) == nil)
    #expect(SHA256Digest(rawValue: "sha256:" + String(repeating: "0", count: 63)) == nil)
    #expect(SHA256Digest(rawValue: "sha256:" + String(repeating: "A", count: 64)) == nil)
    #expect(SHA256Digest(rawValue: "sha256:" + String(repeating: "g", count: 64)) == nil)
  }

  @Test func hashesAndCodableRoundTripsAsOneString() throws {
    let digest = SHA256Digest(hashing: Data("omarchy".utf8))
    let encoded = try JSONEncoder().encode(digest)
    #expect(try JSONDecoder().decode(SHA256Digest.self, from: encoded) == digest)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"\(digest.rawValue)\"")
  }

  @Test func lengthPrefixedHashSeparatesFieldBoundaries() {
    #expect(
      InstallerDigest.lengthPrefixedSHA256(["ab", "c"])
        != InstallerDigest.lengthPrefixedSHA256(["a", "bc"])
    )
  }

  @Test func rejectAudioTuningBlocksAllAudioTuningFingerprintsAndAllowsStockFirmware() throws {
    let stockOutputs: [String: Data] = [
      "apple/aop-calibration.bin": Data("aop".utf8),
      "apple/mesacal-j616s.bin": Data("mesa".utf8),
      "apple/msrk-j616s.bin": Data("msrk".utf8),
      "asmedia/asm2214a-apple.bin": Data("xhci".utf8),
      "brcm/brcmfmac4388-s2-apple,j616s.bin": Data("wifi".utf8),
    ]
    let stockFallback: [String: Data] = [
      "fud_firmware/Firmware/Multitouch.im4p": Data("mt".utf8),
      "firmware/wifi/C-4388__s-B2/kyushu.trx": Data("trx".utf8),
      "com.apple.factorydata/LCfg": Data("lcfg".utf8),
    ]

    let previousHandler = NativeVendorFirmware.noteAudioTuningRejection
    defer { NativeVendorFirmware.noteAudioTuningRejection = previousHandler }

    final class RejectionLog: @unchecked Sendable {
      var names = [String]()
    }
    let noted = RejectionLog()
    NativeVendorFirmware.noteAudioTuningRejection = { name in
      noted.names.append(name)
    }

    try NativeVendorFirmware.rejectAudioTuning(outputs: stockOutputs, fallback: stockFallback)
    #expect(noted.names.isEmpty)

    let bannedPaths = [
      "vendor/apple/audio/AID35/woofer.austrip",
      "vendor/apple/audio/AID35/multiband.dspg",
      "vendor/apple/audio/AID35/volume.propstrip",
      "com.apple.factorydata/speaker-thiele-small",
      "System/Library/Audio/Tunings/Generic/AID35/tuning.plist",
      "asahi/audio-tuning-AID35.tar.gz",
      "etc/wireplumber/wireplumber.conf.d/99-aurora-audio.conf",
      "com.apple.factorydata/acoustic-id",
    ]

    for banned in bannedPaths {
      noted.names.removeAll()
      var taintedOutputs = stockOutputs
      taintedOutputs[banned] = Data("banned".utf8)
      #expect(throws: NativeFirmwareInputFailure.self) {
        try NativeVendorFirmware.rejectAudioTuning(outputs: taintedOutputs, fallback: stockFallback)
      }
      #expect(noted.names == [banned])

      noted.names.removeAll()
      var taintedFallback = stockFallback
      taintedFallback[banned] = Data("banned".utf8)
      #expect(throws: NativeFirmwareInputFailure.self) {
        try NativeVendorFirmware.rejectAudioTuning(outputs: stockOutputs, fallback: taintedFallback)
      }
      #expect(noted.names == [banned])
    }
  }
}
