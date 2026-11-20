#if os(macOS)
  import Darwin
  import Foundation

  /// Byte-exact encoders for the two formats the Python speaker tuning
  /// collector (`asahi_firmware/audio_tuning.py`, `lsm2_fill.py`) writes, so
  /// that the native installer's bundle for a Mac is byte for byte the one the
  /// Python collector writes for the same Mac:
  ///
  /// - `json.dumps(value, sort_keys=True)` with `ensure_ascii`, either with
  ///   `indent=2` (the manifest) or with `separators=(",", ":")` (the lsm2
  ///   fill); and
  /// - `plistlib.dumps(value, fmt=plistlib.FMT_XML)` (the DSP database entry
  ///   reduced to this Mac's key).
  ///
  /// Keys sort by Unicode code point, as Python sorts `str`, not by Swift's
  /// canonical string order.
  enum NativePythonEncoding {
    struct Failure: Error, CustomStringConvertible {
      let description: String
    }

    /// Whether `a` sorts before `b` in Python's `str` order (code points).
    static func precedes(_ a: String, _ b: String) -> Bool {
      a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    // MARK: JSON

    indirect enum JSON: Equatable {
      case null
      case bool(Bool)
      case integer(Int64)
      case string(String)
      case array([JSON])
      case object([String: JSON])

      static func int<T: BinaryInteger>(_ value: T) -> JSON { .integer(Int64(value)) }
      static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
    }

    /// `json.dumps(value, sort_keys=True, indent=2)` when `pretty`, else
    /// `json.dumps(value, sort_keys=True, separators=(",", ":"))`.
    static func json(_ value: JSON, pretty: Bool) -> Data {
      var out = ""
      write(value, level: 0, pretty: pretty, into: &out)
      return Data(out.utf8)
    }

    private static func newline(_ level: Int, _ out: inout String) {
      out += "\n" + String(repeating: " ", count: 2 * level)
    }

    private static func write(_ value: JSON, level: Int, pretty: Bool, into out: inout String) {
      switch value {
      case .null: out += "null"
      case .bool(let flag): out += flag ? "true" : "false"
      case .integer(let number): out += String(number)
      case .string(let text): out += quoted(text)
      case .array(let items):
        guard !items.isEmpty else {
          out += "[]"
          return
        }
        out += "["
        for (index, item) in items.enumerated() {
          if index > 0 { out += "," }
          if pretty { newline(level + 1, &out) }
          write(item, level: level + 1, pretty: pretty, into: &out)
        }
        if pretty { newline(level, &out) }
        out += "]"
      case .object(let members):
        guard !members.isEmpty else {
          out += "{}"
          return
        }
        out += "{"
        for (index, key) in members.keys.sorted(by: precedes).enumerated() {
          if index > 0 { out += "," }
          if pretty { newline(level + 1, &out) }
          out += quoted(key) + (pretty ? ": " : ":")
          write(members[key] ?? .null, level: level + 1, pretty: pretty, into: &out)
        }
        if pretty { newline(level, &out) }
        out += "}"
      }
    }

    private static func hex4(_ value: UInt32) -> String {
      let digits = String(value, radix: 16)
      return "\\u" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// A JSON string as Python writes it with `ensure_ascii`: printable
    /// ASCII stays, the rest becomes `\uXXXX` (surrogate pairs above the
    /// BMP), with the short escapes for `"`, `\`, and five controls.
    static func quoted(_ text: String) -> String {
      var out = "\""
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
          let value = scalar.value
          if (0x20...0x7e).contains(value) {
            out.unicodeScalars.append(scalar)
          } else if value < 0x10000 {
            out += hex4(value)
          } else {
            let offset = value - 0x10000
            out += hex4(0xd800 | (offset >> 10)) + hex4(0xdc00 | (offset & 0x3ff))
          }
        }
      }
      return out + "\""
    }

    // MARK: Property lists

    indirect enum Plist: Equatable {
      case string(String)
      case bool(Bool)
      case integer(Int64)
      case unsigned(UInt64)
      case real(Double)
      case data(Data)
      /// Seconds since 2001-01-01 00:00:00 UTC.
      case date(Double)
      case array([Plist])
      case dictionary([(key: String, value: Plist)])

      static func == (lhs: Plist, rhs: Plist) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.unsigned(let a), .unsigned(let b)): return a == b
        case (.real(let a), .real(let b)): return a.bitPattern == b.bitPattern
        case (.data(let a), .data(let b)): return a == b
        case (.date(let a), .date(let b)): return a.bitPattern == b.bitPattern
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)):
          return a.count == b.count
            && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
      }
    }

    /// A Foundation property list object (as `PropertyListSerialization`
    /// returns it) as the value `plistlib.loads` gives for the same file.
    static func plist(_ object: Any) throws -> Plist {
      let value = object as AnyObject
      let type = CFGetTypeID(value)
      if type == CFStringGetTypeID(), let text = value as? String { return .string(text) }
      if type == CFBooleanGetTypeID() {
        return .bool(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
      }
      if type == CFNumberGetTypeID() {
        let number = unsafeBitCast(value, to: CFNumber.self)
        if CFNumberIsFloatType(number) {
          var real = 0.0
          guard CFNumberGetValue(number, .float64Type, &real) else {
            throw Failure(description: "unreadable real")
          }
          return .real(real)
        }
        var wide: Int64 = 0
        if CFNumberGetValue(number, .sInt64Type, &wide) { return .integer(wide) }
        guard let unsigned = (value as? NSNumber)?.uint64Value else {
          throw Failure(description: "unreadable integer")
        }
        return .unsigned(unsigned)
      }
      if type == CFDataGetTypeID(), let data = value as? Data { return .data(data) }
      if type == CFDateGetTypeID(), let date = value as? Date {
        return .date(date.timeIntervalSinceReferenceDate)
      }
      if type == CFArrayGetTypeID(), let array = value as? NSArray {
        return .array(try array.map { try plist($0) })
      }
      if type == CFDictionaryGetTypeID(), let dictionary = value as? NSDictionary {
        var members = [(key: String, value: Plist)]()
        for (key, member) in dictionary {
          guard CFGetTypeID(key as AnyObject) == CFStringGetTypeID(), let name = key as? String
          else { throw Failure(description: "property list key is not a string") }
          members.append((name, try plist(member)))
        }
        return .dictionary(members)
      }
      throw Failure(description: "unsupported property list type")
    }

    private static let plistHeader =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
      + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"

    /// `plistlib.dumps(value, fmt=plistlib.FMT_XML)`: tab indents, keys in
    /// code point order, `repr` reals, base64 data wrapped by its depth.
    static func xml(_ root: Plist) throws -> Data {
      var out = plistHeader
      line("<plist version=\"1.0\">", 0, &out)
      try xml(root, level: 0, into: &out)
      line("</plist>", 0, &out)
      return Data(out.utf8)
    }

    private static func line(_ text: String, _ level: Int, _ out: inout String) {
      out += String(repeating: "\t", count: level) + text + "\n"
    }

    private static func xml(_ value: Plist, level: Int, into out: inout String) throws {
      switch value {
      case .string(let text):
        line("<string>" + (try escaped(text)) + "</string>", level, &out)
      case .bool(let flag):
        line(flag ? "<true/>" : "<false/>", level, &out)
      case .integer(let number):
        line("<integer>\(number)</integer>", level, &out)
      case .unsigned(let number):
        line("<integer>\(number)</integer>", level, &out)
      case .real(let number):
        line("<real>" + repr(number) + "</real>", level, &out)
      case .date(let seconds):
        line("<date>" + (try date(seconds)) + "</date>", level, &out)
      case .data(let data):
        line("<data>", level, &out)
        let width = max(16, 76 - 8 * level)
        let chunk = (width / 4) * 3
        var start = data.startIndex
        while start < data.endIndex {
          let end = data.index(start, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
          line(data[start..<end].base64EncodedString(), level, &out)
          start = end
        }
        line("</data>", level, &out)
      case .array(let items):
        guard !items.isEmpty else {
          line("<array/>", level, &out)
          return
        }
        line("<array>", level, &out)
        for item in items { try xml(item, level: level + 1, into: &out) }
        line("</array>", level, &out)
      case .dictionary(let members):
        guard !members.isEmpty else {
          line("<dict/>", level, &out)
          return
        }
        line("<dict>", level, &out)
        for member in members.sorted(by: { precedes($0.key, $1.key) }) {
          line("<key>" + (try escaped(member.key)) + "</key>", level + 1, &out)
          try xml(member.value, level: level + 1, into: &out)
        }
        line("</dict>", level, &out)
      }
    }

    /// plistlib's `_escape`: control characters other than tab and line
    /// ends are refused, CR LF and CR become LF, and `&`, `<`, `>` are
    /// escaped.
    static func escaped(_ text: String) throws -> String {
      var out = ""
      var scalars = Array(text.unicodeScalars)[...]
      while let scalar = scalars.popFirst() {
        switch scalar.value {
        case 0x09, 0x0a: out.unicodeScalars.append(scalar)
        case 0x0d:
          if scalars.first == "\n" { scalars.removeFirst() }
          out += "\n"
        case 0x00...0x1f:
          throw Failure(description: "strings can't contain control characters")
        case 0x26: out += "&amp;"
        case 0x3c: out += "&lt;"
        case 0x3e: out += "&gt;"
        default: out.unicodeScalars.append(scalar)
        }
      }
      return out
    }

    /// plistlib's date: the time rounded to microseconds, as `timedelta`
    /// does, written to the second (truncated), in UTC.
    static func date(_ seconds: Double) throws -> String {
      guard seconds.isFinite else { throw Failure(description: "invalid date") }
      let micro = (seconds * 1_000_000).rounded(.toNearestOrEven)
      let whole = (micro / 1_000_000).rounded(.down)
      guard abs(whole) < 1e12 else { throw Failure(description: "invalid date") }
      var time = time_t(Int64(whole) + 978_307_200)
      var parts = tm()
      guard gmtime_r(&time, &parts) != nil else { throw Failure(description: "invalid date") }
      let year = Int(parts.tm_year) + 1900
      guard (1...9999).contains(year) else { throw Failure(description: "invalid date") }
      func two(_ value: Int32) -> String { value < 10 ? "0\(value)" : "\(value)" }
      let padded = String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year)
      return padded + "-" + two(parts.tm_mon + 1) + "-" + two(parts.tm_mday) + "T"
        + two(parts.tm_hour) + ":" + two(parts.tm_min) + ":" + two(parts.tm_sec) + "Z"
    }

    /// Python's `repr(float)`: the shortest digits that round-trip, fixed
    /// notation for decimal exponents -4 < e <= 16 (with `.0` when
    /// integral), else `d.ddde±XX`.
    static func repr(_ value: Double) -> String {
      if value.isNaN { return "nan" }
      if value.isInfinite { return value < 0 ? "-inf" : "inf" }
      let sign = value.sign == .minus ? "-" : ""
      if value == 0 { return sign + "0.0" }
      // Swift's description gives the same shortest round-trip digits;
      // only the layout differs, so take the digits and the exponent from it.
      let text = value.magnitude.description
      var mantissa = Substring(text)
      var exponent = 0
      if let mark = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = text[..<mark]
        exponent =
          Int(text[text.index(after: mark)...].replacingOccurrences(of: "+", with: "")) ?? 0
      }
      var integral = mantissa
      var fraction = Substring("")
      if let dot = mantissa.firstIndex(of: ".") {
        integral = mantissa[..<dot]
        fraction = mantissa[mantissa.index(after: dot)...]
      }
      var digits = Array(integral + fraction)
      var point = integral.count + exponent
      while digits.first == "0" {
        digits.removeFirst()
        point -= 1
      }
      while digits.last == "0" { digits.removeLast() }
      let count = digits.count
      let all = String(digits)
      if point <= -4 || point > 16 {
        let power = point - 1
        let magnitude = String(abs(power))
        let head = String(digits[0]) + (count > 1 ? "." + String(digits[1...]) : "")
        return sign + head + "e" + (power < 0 ? "-" : "+")
          + (magnitude.count < 2 ? "0" + magnitude : magnitude)
      }
      if point <= 0 {
        return sign + "0." + String(repeating: "0", count: -point) + all
      }
      if point >= count {
        return sign + all + String(repeating: "0", count: point - count) + ".0"
      }
      return sign + String(digits[..<point]) + "." + String(digits[point...])
    }
  }
#endif
