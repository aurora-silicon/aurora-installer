// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import AuroraFirmware

struct AVDFirmwareTests {
  // Generated data only. No Apple firmware bytes, instruction sequences or dumps.
  private var synthetic: Data {
    Data((0..<60616).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) })
  }

  private func der(_ tag: UInt8, _ bytes: Data) -> Data {
    var count = bytes.count
    var length = Data()
    repeat {
      length.insert(UInt8(truncatingIfNeeded: count), at: 0)
      count >>= 8
    } while count != 0
    if bytes.count >= 128 { length.insert(0x80 | UInt8(length.count), at: 0) }
    return Data([tag]) + length + bytes
  }

  private func im4p(_ data: Data, type: String = "test") -> Data {
    der(
      0x30,
      der(0x16, Data("IM4P".utf8)) + der(0x16, Data(type.utf8))
        + der(0x16, Data("synthetic".utf8)) + der(4, data))
  }

  @Test func selectedComponentsAreOptionalBoundedAndUnambiguous() throws {
    let spec = AVDFirmware.SoC(
      size: 60616, version: 0x23f3_b998, preloaded: true,
      sources: [
        .init(component: "SyntheticAVD", imageType: "test"),
        .init(component: "SyntheticOther", imageType: "test"),
      ])
    #expect(try AVDFirmware.collect([:], chipID: 0x6040, spec: spec) == nil)
    let file = try #require(
      AVDFirmware.collect(["SyntheticAVD": im4p(synthetic)], chipID: 0x6040, spec: spec))
    #expect(file.bytes == synthetic)
    // A test descriptor never enables an unconfirmed production source rule.
    #expect(try AVDFirmware.collect(["SyntheticAVD": im4p(synthetic)], chipID: 0x6040) == nil)
    for malformed in [
      im4p(synthetic, type: "nope"), im4p(Data(synthetic.dropLast())),
      im4p(synthetic + Data([0])), Data("not DER".utf8),
    ] {
      #expect(throws: RestoreFailure.self) {
        try AVDFirmware.collect(["SyntheticAVD": malformed], chipID: 0x6040, spec: spec)
      }
    }
    #expect(throws: RestoreFailure.self) {
      try AVDFirmware.collect(
        ["SyntheticAVD": im4p(synthetic), "SyntheticOther": im4p(Data(count: 60616))],
        chipID: 0x6040, spec: spec)
    }
  }

  @Test func perSoCNamesAndObservedT6040Identity() throws {
    for soc in AVDFirmware.socs.keys {
      let chip = try #require(UInt64(soc.dropFirst(), radix: 16))
      #expect(AVDFirmware.name(chipID: chip) == "apple/avd-apple-\(soc).bin")
    }
    #expect(AVDFirmware.name(chipID: 0xffff) == nil)
    let spec = try #require(AVDFirmware.socs["t6040"])
    #expect(spec.size == 60616)
    #expect(spec.version == 0x23f3_b998)
    #expect(spec.preloaded)
  }

  @Test func optionalReloadCopyRejectsMalformedPresentImages() throws {
    #expect(try AVDFirmware.reloadImage(nil, chipID: 0x6040) == nil)
    #expect(try AVDFirmware.reloadImage(synthetic, chipID: 0xffff) == nil)
    for chip: UInt64 in [0x6000, 0x8112, 0x8140] {
      #expect(try AVDFirmware.reloadImage(synthetic, chipID: chip) == nil)
    }
    let file = try #require(AVDFirmware.reloadImage(synthetic, chipID: 0x6040))
    #expect(file.name == "apple/avd-apple-t6040.bin")
    #expect(file.bytes == synthetic)
    #expect(file.version == 0x23f3_b998)
    for data in [Data(), Data(synthetic.dropLast()), synthetic + Data([0])] {
      #expect(throws: RestoreFailure.self) {
        try AVDFirmware.reloadImage(data, chipID: 0x6040)
      }
    }
  }

  @Test func packageRecordsVersionAndExactSizeInBothManifests() throws {
    let file = try #require(AVDFirmware.reloadImage(synthetic, chipID: 0x6040))
    let archive = try FirmwarePackageBuilder.build([file])
    let manifest = String(decoding: archive.manifest, as: UTF8.self)
    #expect(manifest.contains("FILE \(file.name) SHA256 \(synthetic.sha256)\n"))
    #expect(manifest.contains("VERSION \(file.name) 0x23f3b998 SIZE 60616\n"))
    #expect(archive.cpio.range(of: archive.manifest) != nil)
    #expect(archive.tar.subdata(in: 512..<(512 + synthetic.count)) == synthetic)
  }

  @Test func unversionedPackagesRetainTheExistingInterchangeBytes() throws {
    struct Fixture: Decodable {
      struct File: Decodable {
        let name: String
        let base64: String
      }
      let files: [File]
      let outputs: [String: String]
    }
    let url = try #require(
      Bundle.module.url(
        forResource: "package-interop", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    let files = try fixture.files.map {
      FirmwarePackageInput(name: $0.name, bytes: try #require(Data(base64Encoded: $0.base64)))
    }
    let result = try FirmwarePackageBuilder.build(files)
    for (name, bytes) in [
      "firmware.tar": result.tar, "firmware.cpio": result.cpio,
      "manifest.txt": result.manifest,
    ] {
      #expect(bytes == Data(base64Encoded: try #require(fixture.outputs[name])))
    }
  }
}
