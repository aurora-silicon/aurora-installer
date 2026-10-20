#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: make-aurora-icon.swift <AuroraLogo.png> <AuroraInstaller.icns>")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSBitmapImageRep(data: try Data(contentsOf: input)),
  let image = source.cgImage
else { fatalError("The source logo is not a bitmap image.") }

// Center the visible mark, rather than its asymmetrically padded source canvas.
var minX = source.pixelsWide
var minY = source.pixelsHigh
var maxX = -1
var maxY = -1
for y in 0..<source.pixelsHigh {
  for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
    minX = min(minX, x)
    minY = min(minY, y)
    maxX = max(maxX, x)
    maxY = max(maxY, y)
  }
}
guard maxX >= minX && maxY >= minY else { fatalError("The source logo is empty.") }
let sourceSize = NSSize(width: source.pixelsWide, height: source.pixelsHigh)
let sourceImage = NSImage(cgImage: image, size: sourceSize)
let crop = NSRect(
  x: minX, y: source.pixelsHigh - maxY - 1,
  width: maxX - minX + 1, height: maxY - minY + 1)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
  "aurora-icon-" + UUID().uuidString)
try FileManager.default.createDirectory(
  at: temporary, withIntermediateDirectories: false,
  attributes: [.posixPermissions: 0o700])
defer {
  do { try FileManager.default.removeItem(at: temporary) } catch {
    FileHandle.standardError.write(Data("Icon staging cleanup failed: \(temporary.path)\n".utf8))
  }
}
let iconset = temporary.appendingPathComponent("AuroraInstaller.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
for (name, pixels) in [
  ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
  ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { fatalError("Cannot allocate an icon representation.") }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
  NSColor.clear.setFill()
  canvas.fill()
  // Keep the original colored ribbon on a fixed neutral gray macOS tile.
  let tile = canvas.insetBy(dx: CGFloat(pixels) / 16, dy: CGFloat(pixels) / 16)
  NSColor(srgbRed: 209 / 255, green: 209 / 255, blue: 214 / 255, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: tile, xRadius: CGFloat(pixels) * 180 / 1024,
    yRadius: CGFloat(pixels) * 180 / 1024
  ).fill()
  let scale = CGFloat(pixels) * 0.625 / max(crop.width, crop.height)
  let size = NSSize(width: crop.width * scale, height: crop.height * scale)
  sourceImage.draw(
    in: NSRect(
      x: (CGFloat(pixels) - size.width) / 2,
      y: (CGFloat(pixels) - size.height) / 2, width: size.width, height: size.height),
    from: crop, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: iconset.appendingPathComponent(name + ".png"))
}
let made = temporary.appendingPathComponent("AuroraInstaller.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", made.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("Native icon packaging failed.") }
try Data(contentsOf: made).write(to: output, options: .atomic)
print(output.path)
