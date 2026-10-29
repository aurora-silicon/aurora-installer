#if os(macOS)
  import Darwin
  import Foundation

  /// Where one installation attempt spent its time.
  ///
  /// Each measured step and each journal record the attempt writes is kept as
  /// one JSON line in `<journal>.timing`, beside the execution journal, and the
  /// helper summarizes the attempt in its diagnostics. Times come from the
  /// monotonic clock, which keeps counting while the Mac sleeps. The first line
  /// of each attempt names the boot session and the wall-clock time at which
  /// that clock was read, so later attempts and restarts stay apart. The
  /// journal's own records keep their exact contract.
  final class InstallerTimingRecorder: @unchecked Sendable {
    @TaskLocal static var current: InstallerTimingRecorder?

    enum Entry: Equatable, Sendable {
      case step(name: String, start: UInt64, end: UInt64, completed: Bool)
      case record(sequence: Int, type: String, name: String, at: UInt64)
    }

    static let fileSuffix = ".timing"
    static let maximumFileBytes = 1 << 20

    let operation: String
    let origin: UInt64
    let started: Date
    let bootSession: String
    private let lock = NSLock()
    private var recorded: [Entry] = []
    private var unwritten: [Data] = []
    private var sidecar: URL?
    private var written = false
    /// Told the name of each measured step as it starts, so a person can see
    /// what the attempt is doing before its first journal record.
    private let observer: (@Sendable (String) -> Void)?

    init(
      operation: String, origin: UInt64 = InstallerTimingRecorder.now(), started: Date = Date(),
      bootSession: String = InstallerTimingRecorder.currentBootSession(),
      observer: (@Sendable (String) -> Void)? = nil
    ) {
      self.operation = operation
      self.observer = observer
      self.origin = origin
      self.started = started
      self.bootSession = bootSession
      unwritten.append(
        Self.line([
          "type": "attempt", "operation": operation, "monotonic_ns": origin,
          "boot": bootSession, "time": Self.timestamp(started),
        ]))
    }

    /// Nanoseconds on the monotonic clock, including time asleep.
    static func now() -> UInt64 {
      clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    static func currentBootSession() -> String {
      var size = 0
      guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
        return ""
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
      return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Runs `body` with a fresh recorder for one attempt of `operation`.
    /// `observe` is told the name of each measured step as it starts.
    static func attempt<T>(
      _ operation: String, isolation: isolated (any Actor)? = #isolation,
      observe: (@Sendable (String) -> Void)? = nil,
      _ body: () async throws -> T
    ) async rethrows -> T {
      let recorder = InstallerTimingRecorder(operation: operation, observer: observe)
      return try await $current.withValue(recorder) {
        try await body()
      }
    }

    /// A measured step starts.
    func begin(_ name: String) {
      observer?(name)
    }

    var entries: [Entry] { lock.withLock { recorded } }

    /// Starts keeping lines beside `journal`. Lines recorded before the
    /// journal's directory exists are written once it does.
    func attach(journal: URL) {
      lock.withLock {
        sidecar = URL(fileURLWithPath: journal.path + Self.fileSuffix)
        flush()
      }
    }

    /// Whether any of this attempt's lines reached the file beside its
    /// journal, which only exists once the attempt reached execution.
    var persisted: Bool { lock.withLock { written } }

    func step(_ name: String, start: UInt64, end: UInt64, completed: Bool) {
      append(
        .step(name: name, start: start, end: end, completed: completed),
        line: [
          "type": "step", "name": name, "start_ns": start, "end_ns": end,
          "completed": completed,
        ])
    }

    func record(sequence: Int, type: String, name: String) {
      let at = Self.now()
      append(
        .record(sequence: sequence, type: type, name: name, at: at),
        line: [
          "type": "record", "record": sequence, "record_type": type, "name": name,
          "at_ns": at,
        ])
    }

    private func append(_ entry: Entry, line: [String: Any]) {
      let bytes = Self.line(line)
      lock.withLock {
        recorded.append(entry)
        unwritten.append(bytes)
        flush()
      }
    }

    /// Best effort: a missing directory keeps the lines for a later write,
    /// and anything unexpected about the file stops writing to it.
    private func flush() {
      guard let sidecar, !unwritten.isEmpty else { return }
      let descriptor = open(
        sidecar.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else {
        if errno != ENOENT { self.sidecar = nil }
        return
      }
      defer { close(descriptor) }
      let bytes = unwritten.reduce(into: Data()) { $0.append($1) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
        Int(info.st_size) + bytes.count <= Self.maximumFileBytes
      else {
        self.sidecar = nil
        return
      }
      let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      guard count == bytes.count else {
        self.sidecar = nil
        return
      }
      unwritten.removeAll()
      written = true
    }

    private static func line(_ object: [String: Any]) -> Data {
      var bytes =
        (try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
      bytes.append(10)
      return bytes
    }

    static func timestamp(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      return formatter.string(from: date)
    }

    /// The attempt as a timeline: when each step started and how long it
    /// took, nested inside the step that contains it, and when each journal
    /// record was written. Seconds count from the start of the attempt.
    var summary: String {
      let entries = self.entries
      var text = """
        started: \(Self.timestamp(started))
        boot session: \(bootSession.isEmpty ? "unknown" : bootSession)
        operation: \(operation)
           start   seconds  step

        """
      func seconds(_ value: UInt64) -> String {
        String(format: "%8.1f", Double(value) / 1_000_000_000)
      }
      func offset(_ value: UInt64) -> UInt64 { value >= origin ? value - origin : 0 }
      let ordered = entries.enumerated().sorted { lhs, rhs in
        func key(_ entry: Entry) -> (UInt64, UInt64) {
          switch entry {
          case .step(_, let start, let end, _): (start, UInt64.max - (end - min(start, end)))
          case .record(_, _, _, let at): (at, 0)
          }
        }
        let (left, right) = (key(lhs.element), key(rhs.element))
        return left != right ? left < right : lhs.offset < rhs.offset
      }
      var open = [UInt64]()
      for (_, entry) in ordered {
        switch entry {
        case .step(let name, let start, let end, let completed):
          while let last = open.last, last <= start { open.removeLast() }
          let indent = String(repeating: "  ", count: open.count)
          let duration = String(format: "%8.2f", Double(end - min(start, end)) / 1_000_000_000)
          text += "\(seconds(offset(start)))  \(duration)  \(indent)\(name)"
          text += completed ? "\n" : " (stopped)\n"
          open.append(end)
        case .record(let sequence, let type, let name, let at):
          while let last = open.last, last <= at { open.removeLast() }
          let indent = String(repeating: "  ", count: open.count)
          text += "\(seconds(offset(at)))         -  \(indent)journal #\(sequence) \(type)"
          text += name.isEmpty ? "\n" : " \(name)\n"
        }
      }
      return text
    }
  }

  extension EngineContractMessage {
    var timingType: String {
      switch self {
      case .inspection: "inspection"
      case .inventory: "inventory"
      case .plan: "plan"
      case .event: "event"
      case .checkpoint: "checkpoint"
      case .completion: "completion"
      }
    }
  }
#endif
