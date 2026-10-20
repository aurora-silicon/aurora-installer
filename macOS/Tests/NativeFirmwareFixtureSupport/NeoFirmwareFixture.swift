import Foundation

public enum NeoFirmwareFixture {
  public static func data() throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: "neo-conversion-vectors", withExtension: "json", subdirectory: "Fixtures")
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
  }
}
