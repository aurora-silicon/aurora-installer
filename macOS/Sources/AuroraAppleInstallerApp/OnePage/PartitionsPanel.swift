import AppKit
import AuroraAppleInstallerTrustCore
import AuroraInstallerUXCore
import SwiftUI

extension EnvironmentValues {
  /// Debug renders only: the row whose ⋯ menu is drawn open.
  @Entry var partitionMenuPreviewRow: String? = nil
}

// MARK: - The screen

/// Partitions on this Mac: every installation, the disk strip, and where
/// another installation can go. Actions only name a row or a target; the
/// session plans it and the removal service checks it again.
struct PartitionsPanel: View {
  @Environment(\.partitionMenuPreviewRow) private var menuPreviewRow
  let layout: DiskLayoutDisplay
  @Binding var selectedOption: String?
  var enabled = true
  var onShrink: (InstallerPlanTarget) -> Void = { _ in }
  var onErase: (DiskLayoutDisplay.Row) -> Void = { _ in }
  var onReset: (DiskLayoutDisplay.Row) -> Void = { _ in }
  var onOpenStartupDisk: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(PlainLanguage.partitionsTitle).font(.system(size: 22, weight: .semibold))
        Text(PlainLanguage.partitionsSubtitle)
          .font(InstallerTheme.body).foregroundStyle(InstallerTheme.secondaryText)
      }
      VStack(spacing: 0) {
        ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { Divider().padding(.leading, 52) }
          PartitionRowView(
            row: row, enabled: enabled, onShrink: onShrink, onErase: onErase, onReset: onReset,
            onOpenStartupDisk: onOpenStartupDisk
          )
          .zIndex(row.id == menuPreviewRow ? 1 : 0)
        }
      }
      .partitionCard()
      if let note = eraseNote {
        Label(note, systemImage: "info.circle")
          .font(InstallerTheme.detail).foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          PartitionSectionTitle(text: "Disk", trailing: PlainLanguage.bytes(layout.totalBytes))
            .fixedSize()
          Spacer(minLength: 12)
          PartitionLegend(kinds: Set(layout.segments.map(\.kind)))
        }
        CaptionedPartitionStrip(segments: layout.segments, highlighted: highlightedSegment)
      }
      VStack(alignment: .leading, spacing: 6) {
        PartitionSectionTitle(text: PlainLanguage.partitionsAddHeading)
        if let reason = layout.noRoomReason {
          NoRoomCard(reason: reason)
        } else {
          ForEach(layout.options) { option in
            PartitionOptionCard(
              option: option, selected: selectedOption == option.id,
              onSelect: { selectedOption = option.id }
            )
            .disabled(!enabled)
          }
        }
      }
    }
  }

  /// One explanation under the list for every Erase that isn't available.
  private var eraseNote: String? {
    layout.rows.compactMap { $0.erase?.reason }.first
  }

  private var highlightedSegment: String? {
    guard let selectedOption, let option = layout.options.first(where: { $0.id == selectedOption })
    else { return nil }
    switch option.target {
    case .freeSpace(let offset): return "free@\(offset)"
    case .shrink(let source): return source
    }
  }
}

// MARK: - Rows

struct PartitionRowView: View {
  @Environment(\.partitionMenuPreviewRow) private var menuPreviewRow
  let row: DiskLayoutDisplay.Row
  var enabled = true
  var onShrink: (InstallerPlanTarget) -> Void = { _ in }
  var onErase: (DiskLayoutDisplay.Row) -> Void = { _ in }
  var onReset: (DiskLayoutDisplay.Row) -> Void = { _ in }
  var onOpenStartupDisk: () -> Void = {}

  var body: some View {
    HStack(spacing: 12) {
      InstallationIcon(icon: row.icon, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(row.detail).font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
          .monospacedDigit()
      }
      Spacer(minLength: 8)
      actions
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
    .accessibilityElement(children: .contain)
    .overlay(alignment: .topTrailing) {
      #if DEBUG
        if menuPreviewRow == row.id {
          PartitionRowMenuPreview(row: row).offset(x: -4, y: 40)
        }
      #endif
    }
  }

  @ViewBuilder private var actions: some View {
    switch row.kind {
    case .macOS:
      if let target = row.shrink {
        Button("Shrink…") { onShrink(target) }
          .partitionRowButton()
          .disabled(!enabled)
      }
    case .aurora:
      let erase = row.erase ?? .unavailable(DiskLayoutDisplay.eraseUnavailableReason)
      Button("Erase…") { onErase(row) }
        .partitionRowButton()
        .disabled(!enabled || !erase.isAvailable)
        .help(erase.reason ?? "Erase \(row.name) and everything stored in it.")
      Menu {
        ForEach(PartitionRowMenu.items(for: row)) { item in
          if item.separatorBefore { Divider() }
          Button {
            switch item.action {
            case .reset: onReset(row)
            case .openStartupDisk: onOpenStartupDisk()
            }
          } label: {
            Label(item.title, systemImage: item.systemImage)
          }
          .disabled(!enabled || !item.enabled)
          .help(item.help ?? "")
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .partitionRowButton()
      .fixedSize()
      .accessibilityLabel("More actions for \(row.name)")
    case .otherLinux:
      Text(PlainLanguage.partitionsNotByAurora)
        .font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
    }
  }
}

/// The row's ⋯ menu, defined once for the menu and its rendered preview.
enum PartitionRowMenu {
  enum Action { case reset, openStartupDisk }

  struct Item: Identifiable {
    let title: String
    let systemImage: String
    let action: Action
    let enabled: Bool
    var help: String?
    var separatorBefore = false
    var id: String { title }
  }

  static func items(for row: DiskLayoutDisplay.Row) -> [Item] {
    let reset = row.reset ?? .unavailable(DiskLayoutDisplay.resetUnavailableReason)
    return [
      Item(
        title: "Reset…", systemImage: "arrow.counterclockwise", action: .reset,
        enabled: reset.isAvailable, help: reset.reason),
      Item(
        title: "Open Startup Disk", systemImage: "externaldrive", action: .openStartupDisk,
        enabled: true, separatorBefore: true),
    ]
  }
}

// MARK: - Options

struct PartitionOptionCard: View {
  let option: DiskLayoutDisplay.Option
  let selected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        Circle()
          .strokeBorder(
            selected ? InstallerTheme.text : InstallerTheme.secondaryText.opacity(0.5),
            lineWidth: selected ? 4.5 : 1.2
          )
          .frame(width: 15, height: 15)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Image(systemName: option.kind == .shrink ? "arrow.left.and.right" : "square.dashed")
              .font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
            Text(option.title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Text(option.sizeText).font(.system(size: 12, weight: .medium)).monospacedDigit()
          }
          Text(option.detail).font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(InstallerTheme.card, in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            selected ? InstallerTheme.text.opacity(0.65) : InstallerTheme.text.opacity(0.1),
            lineWidth: selected ? 1.5 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct NoRoomCard: View {
  let reason: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.system(size: 17)).foregroundStyle(InstallerTheme.secondaryText)
      VStack(alignment: .leading, spacing: 3) {
        Text(PlainLanguage.partitionsNoRoomTitle).font(.system(size: 13, weight: .medium))
        Text(reason).font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .partitionCard()
  }
}

struct PartitionSectionTitle: View {
  let text: String
  var trailing: String?

  var body: some View {
    HStack(spacing: 6) {
      Text(text).font(.system(size: 12, weight: .semibold))
        .foregroundStyle(InstallerTheme.secondaryText)
      Spacer(minLength: 0)
      if let trailing {
        Text(trailing).font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
      }
    }
  }
}

extension View {
  fileprivate func partitionCard() -> some View {
    background(InstallerTheme.card, in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(InstallerTheme.text.opacity(0.1)))
  }

  /// The compact buttons inside a row.
  func partitionRowButton() -> some View {
    controlSize(.regular).font(.system(size: 12)).modifier(AuroraButtonChrome())
  }
}

// MARK: - The disk strip

/// Diagonal hatching for unallocated space, legible in light and dark.
struct PartitionHatch: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      var x: CGFloat = -size.height
      while x < size.width {
        path.move(to: CGPoint(x: x, y: size.height))
        path.addLine(to: CGPoint(x: x + size.height, y: 0))
        x += 6
      }
      context.stroke(path, with: .color(.primary.opacity(0.16)), lineWidth: 1)
    }
  }
}

/// The whole disk in order. Every part gets at least a sliver, so Apple's
/// small system partitions stay visible.
struct PartitionStrip: View {
  static let spacing: CGFloat = 2
  static let minimumWidth: CGFloat = 3
  /// Parts narrower than this are named on leader lines below the strip.
  static let labelWidth: CGFloat = 118

  let segments: [DiskLayoutDisplay.Segment]
  var highlighted: String?
  var height: CGFloat = 40

  var body: some View {
    GeometryReader { geometry in
      let widths = Self.widths(segments.map(\.bytes), width: geometry.size.width)
      HStack(spacing: Self.spacing) {
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
          PartitionSegmentView(segment: segment, width: widths[index])
            .frame(width: widths[index])
            .overlay {
              if segment.id == highlighted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(InstallerTheme.text, lineWidth: 2)
              }
            }
        }
      }
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Disk")
    .accessibilityValue(
      segments.map { "\($0.name) \(PlainLanguage.bytes($0.bytes))" }.joined(separator: ", "))
  }

  /// Proportional widths that fill the strip, with a visible minimum.
  static func widths(_ bytes: [UInt64], width: CGFloat) -> [CGFloat] {
    guard !bytes.isEmpty else { return [] }
    let available = max(0, width - spacing * CGFloat(bytes.count - 1))
    let total = max(1, bytes.reduce(0, +))
    var result = bytes.map { available * CGFloat($0) / CGFloat(total) }
    let small = result.indices.filter { result[$0] < minimumWidth }
    let reserved = minimumWidth * CGFloat(small.count)
    let largeTotal = result.indices.filter { !small.contains($0) }.map { result[$0] }.reduce(0, +)
    for index in result.indices {
      if small.contains(index) {
        result[index] = minimumWidth
      } else if largeTotal > 0 {
        result[index] = result[index] * max(0, available - reserved) / largeTotal
      }
    }
    return result
  }
}

struct PartitionSegmentView: View {
  let segment: DiskLayoutDisplay.Segment
  let width: CGFloat

  var body: some View {
    switch segment.kind {
    case .macOS:
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          InstallerTheme.track
          PartitionColors.macOSUsed
            .frame(
              width: geometry.size.width * CGFloat(segment.usedBytes ?? 0)
                / CGFloat(max(1, segment.bytes)))
          label(
            segment.name,
            "\(PlainLanguage.bytes(segment.bytes)) · \(PlainLanguage.bytes(segment.bytes - min(segment.bytes, segment.usedBytes ?? 0))) free",
            color: InstallerTheme.text)
        }
      }
    case .aurora:
      ZStack {
        InstallerTheme.accent
        label(segment.name, size, color: InstallerTheme.accentText)
      }
    case .otherLinux:
      ZStack {
        PartitionColors.otherLinux
        label(segment.name, size, color: InstallerTheme.accentText)
      }
    case .free:
      ZStack {
        InstallerTheme.track.opacity(0.4)
        PartitionHatch()
        label("Free", size, color: InstallerTheme.secondaryText)
      }
    case .appleSystem:
      PartitionColors.appleSystem
    case .other:
      ZStack {
        PartitionColors.other
        label(segment.name, size, color: InstallerTheme.text)
      }
    }
  }

  private var size: String { PlainLanguage.bytes(segment.bytes) }

  @ViewBuilder
  private func label(_ name: String, _ detail: String, color: Color) -> some View {
    if width >= PartitionStrip.labelWidth {
      VStack(alignment: .leading, spacing: 1) {
        Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        Text(detail).font(.system(size: 11)).monospacedDigit().opacity(0.85).lineLimit(1)
      }
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

enum PartitionColors {
  static let macOSUsed = Color.primary.opacity(0.16)
  static let otherLinux = Color.primary.opacity(0.55)
  static let appleSystem = Color.primary.opacity(0.28)
  static let other = InstallerTheme.secondaryText.opacity(0.25)
}

/// The strip with one caption row: parts too narrow for their name are
/// named below on leader lines, laid out left to right so none overlap.
struct CaptionedPartitionStrip: View {
  let segments: [DiskLayoutDisplay.Segment]
  var highlighted: String?

  private struct Caption {
    let center: CGFloat
    let text: String
    let muted: Bool
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PartitionStrip(segments: segments, highlighted: highlighted)
      GeometryReader { geometry in
        let captions = captions(width: geometry.size.width)
        let placed = Self.place(
          captions.map { ($0.center, Self.textWidth($0.text)) }, width: geometry.size.width)
        ZStack(alignment: .topLeading) {
          Canvas { context, _ in
            for (caption, x) in zip(captions, placed) {
              var path = Path()
              path.move(to: CGPoint(x: caption.center, y: 2))
              path.addLine(to: CGPoint(x: caption.center, y: 6))
              path.addLine(to: CGPoint(x: x, y: 11))
              context.stroke(path, with: .color(.primary.opacity(0.3)), lineWidth: 1)
            }
          }
          ForEach(Array(captions.enumerated()), id: \.offset) { index, caption in
            Text(caption.text)
              .font(.system(size: 11))
              .foregroundStyle(caption.muted ? InstallerTheme.secondaryText : InstallerTheme.text)
              .fixedSize()
              .position(x: placed[index], y: 19)
          }
        }
      }
      .frame(height: hasCaptions ? 27 : 4)
    }
  }

  private var hasCaptions: Bool { !captions(width: 640).isEmpty }

  private func captions(width: CGFloat) -> [Caption] {
    let widths = PartitionStrip.widths(segments.map(\.bytes), width: width)
    var x: CGFloat = 0
    var result = [Caption]()
    for (segment, segmentWidth) in zip(segments, widths) {
      defer { x += segmentWidth + PartitionStrip.spacing }
      guard segmentWidth < PartitionStrip.labelWidth, segment.kind != .appleSystem else { continue }
      let name = segment.kind == .free ? "Free" : segment.name
      result.append(
        Caption(
          center: x + segmentWidth / 2, text: "\(name) · \(PlainLanguage.bytes(segment.bytes))",
          muted: segment.kind == .free))
    }
    return result
  }

  static func textWidth(_ text: String) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
  }

  /// Label centres as close to each part as possible, never overlapping and
  /// never past either edge: a forward sweep, then a backward one.
  static func place(_ items: [(center: CGFloat, width: CGFloat)], width: CGFloat) -> [CGFloat] {
    let gap: CGFloat = 12
    var lefts = [CGFloat]()
    var end: CGFloat = 0
    for item in items {
      let left = max(item.center - item.width / 2, lefts.isEmpty ? 0 : end + gap)
      lefts.append(left)
      end = left + item.width
    }
    var bound = width
    for index in lefts.indices.reversed() {
      lefts[index] = min(lefts[index], bound - items[index].width)
      bound = lefts[index] - gap
    }
    return zip(lefts, items).map { $0 + $1.width / 2 }
  }
}

struct PartitionLegend: View {
  let kinds: Set<DiskLayoutDisplay.SegmentKind>

  var body: some View {
    HStack(spacing: 14) {
      if kinds.contains(.macOS) {
        swatch(
          AnyView(
            InstallerTheme.track.overlay(alignment: .leading) {
              PartitionColors.macOSUsed.frame(width: 7)
            }), "macOS (used / free)")
      }
      if kinds.contains(.aurora) { swatch(AnyView(InstallerTheme.accent), "Aurora") }
      if kinds.contains(.otherLinux) { swatch(AnyView(PartitionColors.otherLinux), "Other Linux") }
      if kinds.contains(.free) {
        swatch(
          AnyView(
            ZStack {
              InstallerTheme.track.opacity(0.4)
              PartitionHatch()
            }), "Unallocated")
      }
      if kinds.contains(.appleSystem) {
        swatch(AnyView(PartitionColors.appleSystem), "Apple system")
      }
      if kinds.contains(.other) { swatch(AnyView(PartitionColors.other), "Other") }
    }
    .font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
  }

  private func swatch(_ fill: AnyView, _ text: String) -> some View {
    HStack(spacing: 5) {
      fill.frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
      Text(text)
    }
  }
}

// MARK: - Sheets

/// Erase confirmation for one row, before the removal service's own review:
/// the disk now and after, and what is and isn't touched.
struct EraseInstallationSheet: View {
  let layout: DiskLayoutDisplay
  let row: DiskLayoutDisplay.Row
  let onCancel: () -> Void
  let onErase: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        InstallationIcon(icon: row.icon, size: 44)
        VStack(alignment: .leading, spacing: 3) {
          Text("Erase \(row.name)?").font(.system(size: 18, weight: .semibold))
          Text("Its files and settings on this Mac are deleted. This can’t be undone.")
            .font(.system(size: 12)).foregroundStyle(InstallerTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        PartitionSectionTitle(text: "Now")
        PartitionStrip(segments: layout.segments, highlighted: row.id)
        PartitionSectionTitle(text: "After").padding(.top, 6)
        PartitionStrip(segments: layout.afterErasing(row.id) ?? layout.segments)
      }
      VStack(alignment: .leading, spacing: 5) {
        Label(
          "Removes its startup volume, EFI partition and Linux partitions (\(PlainLanguage.bytes(row.bytes))).",
          systemImage: "trash")
        if let macOS = layout.macOSRows.first, let growth = layout.macOSGrowthAfterErasing(row.id) {
          Label(
            "\(macOS.name) grows by \(PlainLanguage.bytes(growth)), taking back the free space after it. Its files stay as they are.",
            systemImage: "arrow.left.and.right")
        }
        if let keptText {
          Label(keptText, systemImage: "checkmark.circle")
        }
        Label(
          "Next, the removal service checks the disk again and asks for your password.",
          systemImage: "lock")
      }
      .font(.system(size: 12)).foregroundStyle(InstallerTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel", action: onCancel)
          .auroraSecondaryButton(size: .large).keyboardShortcut(.cancelAction)
        Button("Erase…", role: .destructive, action: onErase)
          .auroraDangerButton(size: .large)
      }
      .padding(.top, 4)
    }
    .padding(24)
    .frame(width: 560)
    .foregroundStyle(InstallerTheme.text)
    .background(InstallerTheme.window)
  }

  /// Every other installation, apart from the macOS that grows.
  private var keptText: String? {
    let grows = layout.macOSRows.first?.id
    let others = layout.rows.filter { $0.id != row.id && $0.id != grows }.map(\.name)
    guard !others.isEmpty else { return nil }
    let list =
      others.count == 1
      ? others[0] : others.dropLast().joined(separator: ", ") + " and " + others[others.count - 1]
    return "\(list) \(others.count == 1 ? "isn’t" : "aren’t") touched."
  }
}

/// Reset: the existing preserved Stage 1 reinstall for this row.
struct ResetInstallationSheet: View {
  let row: DiskLayoutDisplay.Row
  let selection: AuroraInstallationSelection
  let onCancel: () -> Void
  let onReset: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        InstallationIcon(icon: row.icon, size: 44)
        VStack(alignment: .leading, spacing: 3) {
          Text("Reset \(row.name)").font(.system(size: 18, weight: .semibold))
          Text(
            "Advanced. Installs a fresh system into the same \(PlainLanguage.bytes(row.bytes)) and keeps its startup volume, so you don’t go through Recovery again."
          )
          .font(.system(size: 12)).foregroundStyle(InstallerTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        PartitionSectionTitle(text: "Installs")
        Text(systemName).font(.system(size: 13, weight: .medium))
        Text("To install another system, choose it with Choose system first.")
          .font(.system(size: 11)).foregroundStyle(InstallerTheme.secondaryText)
      }
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(InstallerTheme.caution)
        Text("Everything on this installation is erased, including home folders. Back up first.")
          .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(InstallerTheme.caution.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel", action: onCancel)
          .auroraSecondaryButton(size: .large).keyboardShortcut(.cancelAction)
        Button("Reset…", action: onReset)
          .auroraPrimaryButton(size: .large).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
    .foregroundStyle(InstallerTheme.text)
    .background(InstallerTheme.window)
  }

  private var systemName: String {
    selection.distribution.supportsDesktop
      ? "\(selection.distribution.title) with \(selection.desktop.title)"
      : selection.distribution.title
  }
}
