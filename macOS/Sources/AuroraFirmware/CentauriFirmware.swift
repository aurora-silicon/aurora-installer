// SPDX-License-Identifier: MIT
import Foundation

/// The Apple N1 (Centauri) Wi-Fi and Bluetooth firmware. One FTAB image
/// serves both radios. The restore image ships one image per N1 generation
/// and one ticket per Mac model, and the N1's boot ROM starts an image only
/// with its model's ticket in it: the ticket is appended to the image, and
/// the image's header names it (its offset at 0x10 and its size at 0x14,
/// little endian). Inputs are this Mac's own restore files, never shipped.
/// `asahi_firmware/centauri.py` is the same conversion.
public enum CentauriFirmware {
  /// The driver loads at most 64 MiB.
  public static let maximumBytes = 64 << 20
  public static let maximumTicketBytes = 1 << 20

  /// The model's ticket in the restore directory's `centauri/`, which holds
  /// the restore image's `Firmware/Manifests/restore/<variant>/centauri/`.
  public static func ticketPath(deviceClass: String) -> String {
    "centauri/centauri." + deviceClass + ".im4m"
  }

  // TODO: remove once a released kernel's T8152 driver requests the model's
  // own name (or reads the device tree's `firmware-name`, as the T6050
  // driver does).
  /// The T8152 driver's board table names the J873g's file after the J873;
  /// every other N1 board's driver requests its model's name (the T6050
  /// device trees' `firmware-name` and the T8142 board table).
  static let kernelModel = ["j873g": "j873"]

  /// The file the N1 driver requests on this model.
  public static func firmwareName(machine: String) -> String {
    "apple/centauri/" + (kernelModel[machine] ?? machine) + "-ftab.bin"
  }

  /// The two inputs as `asahi/all_firmware.tar.gz` keeps them, so that
  /// `asahi_firmware`'s rebuild on Linux makes the same file:
  /// `centauri/<model>/ftab.bin` and the ticket by its own name beside it.
  public static func fallback(machine: String, image: Data, ticket: Data) -> [String: Data] {
    let directory = "centauri/" + machine + "/"
    return [
      directory + "ftab.bin": image,
      directory + "centauri." + machine + "ap.im4m": ticket,
    ]
  }

  /// The image with the ticket appended and named in its header.
  public static func personalize(image: Data, ticket: Data) throws -> Data {
    let image = Data(image)
    try require(
      image.count >= 0x30 && image.count <= maximumBytes - ticket.count,
      "The N1 image is out of bounds.")
    try require(image[0x20..<0x28].elementsEqual("rkosftab".utf8), "The N1 image is not an FTAB.")
    let ticketOffset = try image.little(0x10, 4)
    let ticketSize = try image.little(0x14, 4)
    try require(ticketOffset == 0 && ticketSize == 0, "The N1 image already carries a ticket.")
    try validateTicket(ticket)
    var output = image
    output.replaceSubrange(0x10..<0x14, with: littleBytes(image.count, count: 4))
    output.replaceSubrange(0x14..<0x18, with: littleBytes(ticket.count, count: 4))
    output.append(ticket)
    return output
  }

  /// An IMG4 manifest: one DER sequence that is the whole file and starts
  /// with the string `IM4M`.
  static func validateTicket(_ ticket: Data) throws {
    let ticket = Data(ticket)
    try require(
      !ticket.isEmpty && ticket.count <= maximumTicketBytes && ticket[0] == 0x30,
      "The N1 ticket is not a manifest.")
    let manifest = try FirmwareDER.element(ticket, at: 0, limit: ticket.count)
    try require(manifest.whole == 0..<ticket.count, "The N1 ticket has trailing bytes.")
    let fields = try FirmwareDER.children(ticket, manifest)
    try require(
      !fields.isEmpty && FirmwareDER.text(ticket, fields[0], "IM4M"),
      "The N1 ticket is not a manifest.")
  }
}
