#if os(macOS)
  import Foundation

  /// Friendly names for Apple Silicon device identifiers (`hw.targettype`).
  ///
  /// Names only: which Macs a release supports always comes from its signed
  /// catalog. A catalog identifier missing here is still listed, by its
  /// identifier, so a new catalog entry can never disappear from the message.
  public enum MacModelNames {
    public struct Entry: Equatable, Sendable {
      public let name: String
      public let family: String
      public let chipGeneration: String
    }

    public static func entry(for deviceIdentifier: String) -> Entry? {
      table[deviceIdentifier.lowercased()]
    }

    public static func name(for deviceIdentifier: String) -> String? {
      entry(for: deviceIdentifier)?.name
    }

    /// "M1: iMac, Mac mini, … M2: …", then any identifiers without a name.
    /// Nil for an empty list.
    public static func supportedFamiliesSummary(_ deviceIdentifiers: [String]) -> String? {
      var families = [String: Set<String>]()
      var unnamed = [String]()
      for identifier in Set(deviceIdentifiers) {
        if let entry = entry(for: identifier) {
          families[entry.chipGeneration, default: []].insert(entry.family)
        } else {
          unnamed.append(identifier)
        }
      }
      var parts = families.keys.sorted().map { generation in
        let names = families[generation, default: []].sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return "\(generation): \(names.joined(separator: ", "))"
      }
      if !unnamed.isEmpty {
        parts.append("also \(unnamed.sorted().joined(separator: ", "))")
      }
      return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private static func mac(
      _ name: String, _ family: String, _ generation: String
    ) -> Entry {
      Entry(name: name, family: family, chipGeneration: generation)
    }

    private static let table: [String: Entry] = [
      "apple,j274": mac("Mac mini (M1, 2020)", "Mac mini", "M1"),
      "apple,j293": mac("MacBook Pro 13-inch (M1, 2020)", "MacBook Pro", "M1"),
      "apple,j313": mac("MacBook Air (M1, 2020)", "MacBook Air", "M1"),
      "apple,j456": mac("iMac 24-inch (M1, 2021, four ports)", "iMac", "M1"),
      "apple,j457": mac("iMac 24-inch (M1, 2021, two ports)", "iMac", "M1"),
      "apple,j314s": mac("MacBook Pro 14-inch (M1 Pro, 2021)", "MacBook Pro", "M1"),
      "apple,j314c": mac("MacBook Pro 14-inch (M1 Max, 2021)", "MacBook Pro", "M1"),
      "apple,j316s": mac("MacBook Pro 16-inch (M1 Pro, 2021)", "MacBook Pro", "M1"),
      "apple,j316c": mac("MacBook Pro 16-inch (M1 Max, 2021)", "MacBook Pro", "M1"),
      "apple,j375c": mac("Mac Studio (M1 Max, 2022)", "Mac Studio", "M1"),
      "apple,j375d": mac("Mac Studio (M1 Ultra, 2022)", "Mac Studio", "M1"),
      "apple,j413": mac("MacBook Air 13-inch (M2, 2022)", "MacBook Air", "M2"),
      "apple,j415": mac("MacBook Air 15-inch (M2, 2023)", "MacBook Air", "M2"),
      "apple,j493": mac("MacBook Pro 13-inch (M2, 2022)", "MacBook Pro", "M2"),
      "apple,j473": mac("Mac mini (M2, 2023)", "Mac mini", "M2"),
      "apple,j474s": mac("Mac mini (M2 Pro, 2023)", "Mac mini", "M2"),
      "apple,j414s": mac("MacBook Pro 14-inch (M2 Pro, 2023)", "MacBook Pro", "M2"),
      "apple,j414c": mac("MacBook Pro 14-inch (M2 Max, 2023)", "MacBook Pro", "M2"),
      "apple,j416s": mac("MacBook Pro 16-inch (M2 Pro, 2023)", "MacBook Pro", "M2"),
      "apple,j416c": mac("MacBook Pro 16-inch (M2 Max, 2023)", "MacBook Pro", "M2"),
      "apple,j475c": mac("Mac Studio (M2 Max, 2023)", "Mac Studio", "M2"),
      "apple,j475d": mac("Mac Studio (M2 Ultra, 2023)", "Mac Studio", "M2"),
      "apple,j180d": mac("Mac Pro (M2 Ultra, 2023)", "Mac Pro", "M2"),
      "apple,j433": mac("iMac 24-inch (M3, 2023)", "iMac", "M3"),
      "apple,j434": mac("iMac 24-inch (M3, 2023)", "iMac", "M3"),
      "apple,j504": mac("MacBook Pro 14-inch (M3, 2023)", "MacBook Pro", "M3"),
      "apple,j514s": mac("MacBook Pro 14-inch (M3 Pro, 2023)", "MacBook Pro", "M3"),
      "apple,j514c": mac("MacBook Pro 14-inch (M3 Max, 2023)", "MacBook Pro", "M3"),
      "apple,j514m": mac("MacBook Pro 14-inch (M3 Max, 2023)", "MacBook Pro", "M3"),
      "apple,j516s": mac("MacBook Pro 16-inch (M3 Pro, 2023)", "MacBook Pro", "M3"),
      "apple,j516c": mac("MacBook Pro 16-inch (M3 Max, 2023)", "MacBook Pro", "M3"),
      "apple,j516m": mac("MacBook Pro 16-inch (M3 Max, 2023)", "MacBook Pro", "M3"),
      "apple,j575d": mac("Mac Studio (M3 Ultra, 2025)", "Mac Studio", "M3"),
      "apple,j613": mac("MacBook Air 13-inch (M3, 2024)", "MacBook Air", "M3"),
      "apple,j615": mac("MacBook Air 15-inch (M3, 2024)", "MacBook Air", "M3"),
      "apple,j604": mac("MacBook Pro 14-inch (M4, 2024)", "MacBook Pro", "M4"),
      "apple,j623": mac("iMac 24-inch (M4, 2024, two ports)", "iMac", "M4"),
      "apple,j624": mac("iMac 24-inch (M4, 2024, four ports)", "iMac", "M4"),
      "apple,j713": mac("MacBook Air 13-inch (M4, 2025)", "MacBook Air", "M4"),
      "apple,j715": mac("MacBook Air 15-inch (M4, 2025)", "MacBook Air", "M4"),
      "apple,j773g": mac("Mac mini (M4, 2024)", "Mac mini", "M4"),
      "apple,j614s": mac("MacBook Pro 14-inch (M4 Pro, 2024)", "MacBook Pro", "M4"),
      "apple,j614c": mac("MacBook Pro 14-inch (M4 Max, 2024)", "MacBook Pro", "M4"),
      "apple,j616s": mac("MacBook Pro 16-inch (M4 Pro, 2024)", "MacBook Pro", "M4"),
      "apple,j616c": mac("MacBook Pro 16-inch (M4 Max, 2024)", "MacBook Pro", "M4"),
      "apple,j773s": mac("Mac mini (M4 Pro, 2024)", "Mac mini", "M4"),
      "apple,j575c": mac("Mac Studio (M4 Max, 2025)", "Mac Studio", "M4"),
      "apple,j813": mac("MacBook Air 13-inch (M5, 2026)", "MacBook Air", "M5"),
      "apple,j704": mac("MacBook Pro (14-inch, M5)", "MacBook Pro", "M5"),
      "apple,j815": mac("MacBook Air (15-inch, M5)", "MacBook Air", "M5"),
      "apple,j873g": mac("Mac mini (M6)", "Mac mini", "M6"),
      "apple,j804": mac("MacBook Pro (14-inch, M6)", "MacBook Pro", "M6"),
      "apple,j833ct": mac("iMac (24-inch, M6)", "iMac", "M6"),
      "apple,j700": mac("MacBook Neo (A18 Pro, 2026)", "MacBook Neo", "A18 Pro"),
      "apple,k114c": mac("MacBook Pro 14-inch OLED (M5 Max, 2026)", "MacBook Pro", "M5"),
      "apple,k114s": mac("MacBook Pro 14-inch OLED (M5 Pro, 2026)", "MacBook Pro", "M5"),
      "apple,k116c": mac("MacBook Pro 16-inch OLED (M5 Max, 2026)", "MacBook Pro", "M5"),
      "apple,k116s": mac("MacBook Pro 16-inch OLED (M5 Pro, 2026)", "MacBook Pro", "M5"),
    ]
  }
#endif
