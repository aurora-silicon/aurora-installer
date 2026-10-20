import AppKit
import OmarchyInstallerUXCore
import SwiftUI

// MARK: - Building blocks

struct NativeSpinner: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.controlSize) private var controlSize

  func makeNSView(context: Context) -> NSProgressIndicator {
    let view = NSProgressIndicator()
    view.style = .spinning
    view.isIndeterminate = true
    view.usesThreadedAnimation = true
    return view
  }

  func updateNSView(_ view: NSProgressIndicator, context: Context) {
    view.controlSize = isSmall ? .small : .regular
    view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    view.startAnimation(nil)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSProgressIndicator, context: Context
  ) -> CGSize? {
    let side = isSmall ? 16.0 : 32.0
    return CGSize(width: side, height: side)
  }

  static func dismantleNSView(_ view: NSProgressIndicator, coordinator: ()) {
    view.stopAnimation(nil)
  }

  private var isSmall: Bool { controlSize == .small || controlSize == .mini }
}

struct Panel<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .fill(OmarchyTheme.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .strokeBorder(OmarchyTheme.separator.opacity(0.45), lineWidth: 0.5)
    )
  }
}

struct FactGrid: View {
  let rows: [PlanFactRow]
  var labelWidth: CGFloat = 118

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.label)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .frame(width: labelWidth, alignment: .leading)
          Text(row.value)
            .font(row.isMonospaced ? OmarchyTheme.technical : OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
      }
    }
  }
}

struct StatusBadge: View {
  enum Kind { case ok, blocked }

  let text: String
  let kind: Kind

  var body: some View {
    Text(text)
      .font(OmarchyTheme.badge)
      .tracking(OmarchyTheme.buttonTracking)
      .foregroundStyle(
        kind == .ok ? OmarchyTheme.secondaryText : OmarchyTheme.danger
      )
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(
          kind == .ok ? OmarchyTheme.track : OmarchyTheme.danger.opacity(0.1)
        )
      )
  }
}

struct DiskBar: View {
  let macOSBytes: UInt64
  let omarchyBytes: UInt64
  var unallocatedBytes: UInt64 = 0
  var otherAllocatedBytes: UInt64 = 0
  var macOSSpaceCaution: String?
  /// When set, the divider between the segments is draggable and reports the
  /// Aurora share of the disk (0...1) as it moves.
  var onAdjustOmarchyFraction: ((Double) -> Void)?
  /// Called once when the drag ends, with the final Aurora share.
  var onCommitOmarchyFraction: ((Double) -> Void)?
  /// While set, the divider is drawn but drags are ignored (a re-plan is in
  /// flight). Keeping the handle on screen avoids it flashing off and on.
  var isFrozen = false

  var body: some View {
    GeometryReader { geometry in
      let total = max(
        1,
        Double(macOSBytes) + Double(omarchyBytes) + Double(unallocatedBytes)
          + Double(otherAllocatedBytes))
      let width = geometry.size.width
      let omarchyWidth = width * Double(omarchyBytes) / total
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          segment(
            name: "macOS", bytes: macOSBytes,
            width: width * Double(macOSBytes) / total,
            background: macOSSpaceCaution == nil
              ? OmarchyTheme.track : OmarchyTheme.caution.opacity(0.2),
            foreground: OmarchyTheme.secondaryText)
          if otherAllocatedBytes > 0 {
            segment(
              name: "Other", bytes: otherAllocatedBytes,
              width: width * Double(otherAllocatedBytes) / total,
              background: OmarchyTheme.secondaryText.opacity(0.25),
              foreground: OmarchyTheme.secondaryText)
          }
          if unallocatedBytes > 0 {
            segment(
              name: "Free", bytes: unallocatedBytes,
              width: width * Double(unallocatedBytes) / total,
              background: OmarchyTheme.track.opacity(0.4), foreground: OmarchyTheme.secondaryText)
          }
          segment(
            name: "Aurora", bytes: omarchyBytes, width: omarchyWidth,
            background: OmarchyTheme.accent, foreground: OmarchyTheme.accentText)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        if onAdjustOmarchyFraction != nil {
          Image(systemName: "arrow.left.and.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.7))
            .frame(width: 26, height: 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .offset(x: min(max(0, width - omarchyWidth - 13), width - 26))
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard !isFrozen else { return }
            let x = min(max(0, value.location.x), width)
            onAdjustOmarchyFraction?(1 - Double(x / max(1, width)))
          }
          .onEnded { value in
            guard !isFrozen else { return }
            let x = min(max(0, value.location.x), width)
            onCommitOmarchyFraction?(1 - Double(x / max(1, width)))
          },
        including: onAdjustOmarchyFraction == nil ? .none : .all
      )
    }
    .frame(height: 54)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Disk space")
    .accessibilityValue(
      "macOS \(PlainLanguage.bytes(macOSBytes)), Aurora \(PlainLanguage.bytes(omarchyBytes)), unallocated \(PlainLanguage.bytes(unallocatedBytes))"
        + (otherAllocatedBytes > 0
          ? ", other storage \(PlainLanguage.bytes(otherAllocatedBytes))" : "")
        + (macOSSpaceCaution.map { ". " + $0 } ?? "")
    )
    .accessibilityAdjustableAction { direction in
      guard !isFrozen else { return }
      let total = max(
        1,
        Double(macOSBytes) + Double(omarchyBytes) + Double(unallocatedBytes)
          + Double(otherAllocatedBytes))
      let change: Double
      switch direction {
      case .increment: change = 1_000_000_000
      case .decrement: change = -1_000_000_000
      @unknown default: return
      }
      onCommitOmarchyFraction?(min(1, max(0, (Double(omarchyBytes) + change) / total)))
    }
  }

  private func segment(
    name: String,
    bytes: UInt64,
    width: CGFloat,
    background: Color,
    foreground: Color
  ) -> some View {
    ZStack {
      background
      if width >= 68 {
        Text(name)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(foreground)
          .lineLimit(1)
          .padding(.horizontal, 8)
      }
    }
    .frame(width: max(0, width))
  }
}

struct ProgressTrack: View {
  let fraction: Double?
  var height: CGFloat = 4

  var body: some View {
    ProgressView(value: fraction.map { min(1, max(0, $0)) })
      .progressViewStyle(.linear).controlSize(.small).tint(.gray)
      .frame(height: height)
  }
}

struct RecoveryStepRow: View {
  let step: RecoveryStep

  var body: some View {
    HStack(alignment: .center, spacing: 13) {
      Text("\(step.number)")
        .font(OmarchyTheme.numeral)
        .foregroundStyle(OmarchyTheme.accentText)
        .frame(width: 24, height: 24)
        .background(Circle().fill(OmarchyTheme.accent))
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title)
          .font(OmarchyTheme.heading)
        if let detail = step.detail {
          Text(detail)
            .omarchyHelpText()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .fill(OmarchyTheme.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .strokeBorder(OmarchyTheme.separator, lineWidth: 1)
    )
  }
}

/// Raw error text, kept verbatim so nothing is lost behind plain language.
struct TechnicalDetailText: View {
  let text: String

  var body: some View {
    Text(text)
      .font(OmarchyTheme.technical)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(OmarchyTheme.window)
      )
  }
}

extension View {
  func omarchyPrimaryButton() -> some View {
    buttonStyle(.plain).font(.system(size: 15, weight: .medium)).controlSize(.large)
      .padding(.horizontal, 18).padding(.vertical, 9).contentShape(Rectangle())
  }
  func nativeInstallButton() -> some View {
    buttonStyle(.bordered).controlSize(.large).tint(.gray)
      .font(.system(size: 15, weight: .medium))
  }
  func omarchySecondaryButton() -> some View { buttonStyle(.bordered).controlSize(.large) }
  func omarchyDangerButton() -> some View { buttonStyle(.bordered).tint(.red).controlSize(.large) }
}

struct PreparationStatusPanel: View {
  var body: some View {
    VStack(spacing: 18) {
      Text("Getting everything ready").font(.system(size: 20, weight: .medium))
      NativeSpinner().controlSize(.regular)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
