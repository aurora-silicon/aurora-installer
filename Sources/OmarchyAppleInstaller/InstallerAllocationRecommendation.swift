import Foundation

public enum APFSSnapshotConstraint: Equatable, Sendable {
  case timeMachine
  case other
}

public enum InstallerAllocationRecommendationError:
  Error, Equatable, Sendable
{
  case noEligibleCandidate
  case snapshotConstrained(APFSSnapshotConstraint)
  /// A free extent or resizable container exists, but the most it can give
  /// Omarchy is below the install minimum.
  case insufficientSpace(requiredBytes: UInt64, availableBytes: UInt64)
}

public struct InstallerAllocationRecommendation:
  Equatable, Sendable
{
  public static let balancedTargetBytes: UInt64 = 137_438_953_472

  /// `minimumContainerBytes` follows live macOS usage and the layout digest
  /// does not cover it, so writes the installer does not account for in
  /// `reservedBytes` still lower the ceiling the engine checks at admission.
  /// A resize candidate withholds this share of what remains, up to the cap.
  static let resizeDriftMarginDivisor: UInt64 = 20
  static let maximumResizeDriftMarginBytes: UInt64 = 8_589_934_592

  public let candidate: ValidatedEngineCandidate
  public let minimumBytes: UInt64
  public let maximumBytes: UInt64
  public let requestedLengthBytes: UInt64

  public init(
    inventory: ValidatedEngineInventory,
    targetBytes: UInt64 = Self.balancedTargetBytes,
    reservedBytes: UInt64 = 0,
    snapshotConstraint: () -> APFSSnapshotConstraint? = { nil }
  ) throws {
    let unit = PinnedAsahiPlanRequest.allocationUnitBytes
    let ranked = inventory.candidates.compactMap { candidate -> Ranked? in
      var minimum = Self.alignUp(
        candidate.minimumInstallBytes,
        unit: unit
      )
      let maximum: UInt64
      if candidate.kind == "free" {
        // A free extent is fixed on the partition map: nothing recomputes it
        // between planning and execution, so it needs no reserve or margin.
        maximum = candidate.lengthBytes
      } else if candidate.kind == "resize",
        candidate.lengthBytes > candidate.minimumContainerBytes
      {
        let available = candidate.lengthBytes - candidate.minimumContainerBytes
        guard available > reservedBytes else {
          return nil
        }
        // The engine's hard container floor already protects macOS. A second
        // recommendation threshold can shrink the range as free space grows.
        let usable = available - reservedBytes
        let margin = min(
          usable / Self.resizeDriftMarginDivisor,
          Self.maximumResizeDriftMarginBytes
        )
        let marginCeiling = usable - margin
        // The doubled size becomes the minimum only when it stays below the
        // margin, so the divider keeps a range and the engine its drift room.
        if let recommended = candidate.recommendedInstallBytes {
          let alignedRecommended = Self.alignUp(recommended, unit: unit)
          if alignedRecommended < marginCeiling - (marginCeiling % unit) {
            minimum = alignedRecommended
          }
        }
        // The margin is best effort: on a tight disk keep what fits above the
        // partition floor rather than dropping a candidate the reserve allows.
        maximum = min(usable, max(marginCeiling, minimum))
      } else {
        return nil
      }

      let alignedMaximum = maximum - (maximum % unit)
      guard minimum <= alignedMaximum else {
        return nil
      }
      return Ranked(
        candidate: candidate,
        minimum: minimum,
        maximum: alignedMaximum
      )
    }.sorted { left, right in
      if left.candidate.kind != right.candidate.kind {
        return left.candidate.kind == "free"
      }
      if left.maximum != right.maximum {
        return left.maximum > right.maximum
      }
      return left.candidate.sourceIdentifier
        < right.candidate.sourceIdentifier
    }

    guard let selected = ranked.first else {
      // Existing installations require an explicit choice before any space diagnosis.
      guard
        !inventory.candidates.contains(where: { $0.kind == "repair" || $0.kind == "replace" })
      else {
        throw InstallerAllocationRecommendationError.noEligibleCandidate
      }
      if let constraint = snapshotConstraint() {
        throw InstallerAllocationRecommendationError.snapshotConstrained(constraint)
      }
      if let shortfall = Self.largestShortfall(
        in: inventory, reservedBytes: reservedBytes
      ) {
        throw InstallerAllocationRecommendationError.insufficientSpace(
          requiredBytes: shortfall.required,
          availableBytes: shortfall.available
        )
      }
      throw InstallerAllocationRecommendationError.noEligibleCandidate
    }
    let alignedTarget = targetBytes - (targetBytes % unit)
    candidate = selected.candidate
    minimumBytes = selected.minimum
    maximumBytes = selected.maximum
    requestedLengthBytes = min(
      selected.maximum,
      max(selected.minimum, alignedTarget)
    )
  }

  /// The free or resize candidate that comes closest to the install minimum,
  /// measured the way the ranking above admits candidates. Nil when the
  /// inventory offers no such candidate at all.
  private static func largestShortfall(
    in inventory: ValidatedEngineInventory,
    reservedBytes: UInt64
  ) -> (required: UInt64, available: UInt64)? {
    let unit = PinnedAsahiPlanRequest.allocationUnitBytes
    return inventory.candidates.compactMap { candidate -> (UInt64, UInt64)? in
      let usable: UInt64
      var deficit: UInt64 = 0
      switch candidate.kind {
      case "free":
        usable = candidate.lengthBytes
      case "resize":
        let shrinkable =
          candidate.lengthBytes - min(candidate.lengthBytes, candidate.minimumContainerBytes)
        usable = shrinkable - min(shrinkable, reservedBytes)
        deficit = Self.saturatingAdd(
          candidate.minimumContainerBytes
            - min(candidate.minimumContainerBytes, candidate.lengthBytes),
          reservedBytes - min(reservedBytes, shrinkable))
      default:
        return nil
      }
      return (
        Self.saturatingAdd(alignUp(candidate.minimumInstallBytes, unit: unit), deficit),
        usable - (usable % unit)
      )
    }.min { ($0.0 - min($0.0, $0.1)) < ($1.0 - min($1.0, $1.1)) }
  }

  private static func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let (result, overflow) = left.addingReportingOverflow(right)
    return overflow ? UInt64.max : result
  }

  private static func alignUp(
    _ value: UInt64,
    unit: UInt64
  ) -> UInt64 {
    let remainder = value % unit
    guard remainder != 0 else {
      return value
    }
    let adjustment = unit - remainder
    let (result, overflow) = value.addingReportingOverflow(adjustment)
    return overflow ? UInt64.max : result
  }

  private struct Ranked {
    let candidate: ValidatedEngineCandidate
    let minimum: UInt64
    let maximum: UInt64
  }
}
