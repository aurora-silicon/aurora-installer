#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import Darwin
  import Foundation
  import Observation

  /// The Installer Log window's filter, worded as Apple's Installer Log.
  public enum InstallerLogFilter: String, CaseIterable, Identifiable, Sendable {
    case errorsOnly
    case errorsAndProgress
    case all

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .errorsOnly: "Errors only"
      case .errorsAndProgress: "Errors and progress"
      case .all: "Everything"
      }
    }

    public var maximumLevel: InstallerLogLevel {
      switch self {
      case .errorsOnly: .error
      case .errorsAndProgress: .progress
      case .all: .debug
      }
    }

    public func admits(_ entry: InstallerLogEntry) -> Bool { entry.level <= maximumLevel }
  }

  /// How log lines read on screen and in saved files.
  public enum InstallerLogFormat {
    /// The lines `filter` admits that contain `search`, ignoring case, in
    /// their message or source.
    public static func visible(
      _ entries: [InstallerLogEntry], filter: InstallerLogFilter, search: String
    ) -> [InstallerLogEntry] {
      let needle = search.trimmingCharacters(in: .whitespaces)
      return entries.filter { entry in
        filter.admits(entry)
          && (needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle)
            || entry.source.localizedCaseInsensitiveContains(needle))
      }
    }

    // DateFormatter is safe to share for formatting.
    private static let clockFormatter = formatter("HH:mm:ss.SSS")
    private static let timestampFormatter = formatter(
      "yyyy-MM-dd HH:mm:ss.SSSZ")

    private static func formatter(_ format: String) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.dateFormat = format
      return formatter
    }

    /// `14:03:11.123`, local time, for the window.
    public static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// `2026-11-02 14:03:11.123+0100`, for saved files.
    public static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    /// One line of a saved or persisted log: time, level, source, message.
    public static func fileLine(_ entry: InstallerLogEntry) -> String {
      let level = entry.level.label.padding(toLength: 5, withPad: " ", startingAt: 0)
      return "\(timestamp(entry.time)) \(level) \(entry.source): \(entry.message)"
    }

    /// A saved log: a header naming what was shown, then the lines.
    public static func document(
      _ entries: [InstallerLogEntry], filter: InstallerLogFilter, search: String, now: Date = Date()
    ) -> String {
      var text = "\(InstallerProductIdentity.appName) log, saved \(timestamp(now))\n"
      text += "Filter: \(filter.title)"
      if !search.trimmingCharacters(in: .whitespaces).isEmpty { text += ", matching “\(search)”" }
      text += "\n\n"
      for entry in entries { text += fileLine(entry) + "\n" }
      return text
    }
  }

  /// The person's own copy of the log, in `~/Library/Logs/<app name>/`: every
  /// level, appended as it happens, so a failed installation leaves the whole
  /// log behind. The file is the person's (0600 in a 0700 folder); the
  /// helper's root-only diagnostics stay where they are. It is kept under
  /// `maximumFileBytes`, then moved aside as `installer.1.log`, keeping
  /// `retainedFiles` older files. Writing happens on its own queue; when the
  /// disk falls behind by `maximumPendingBytes`, lines are dropped and the
  /// count is written once it catches up.
  public final class InstallerLogFile: @unchecked Sendable {
    public static let fileName = "installer.log"
    public static let maximumFileBytes = 4 << 20
    public static let retainedFiles = 2
    public static let maximumPendingBytes = 2 << 20

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }
    private let maximumFileBytes: Int
    private let queue = DispatchQueue(label: InstallerProductIdentity.appIdentifier + ".log-file")
    private let lock = NSLock()
    private var pendingBytes = 0
    private var dropped = 0
    private var descriptor: Int32 = -1
    private var folder: Int32 = -1
    private var size = 0
    private var failed = false

    public init(directory: URL, maximumFileBytes: Int = InstallerLogFile.maximumFileBytes) {
      self.directory = directory
      self.maximumFileBytes = maximumFileBytes
    }

    deinit {
      if descriptor >= 0 { Darwin.close(descriptor) }
      if folder >= 0 { Darwin.close(folder) }
    }

    /// `~/Library/Logs/<app name>/`, beside the app's failure notices.
    public static func defaultDirectory() -> URL? { EngineFailureUserLog.defaultDirectory() }

    public func append(_ entry: InstallerLogEntry) {
      append(line: InstallerLogFormat.fileLine(entry))
    }

    public func append(line: String) {
      let data = Data((line + "\n").utf8)
      let admitted = lock.withLock {
        guard pendingBytes + data.count <= Self.maximumPendingBytes else {
          dropped += 1
          return false
        }
        pendingBytes += data.count
        return true
      }
      guard admitted else { return }
      queue.async { [self] in
        write(data)
        // Report drops once the queue is empty, and only then forget them.
        let missed = lock.withLock {
          pendingBytes -= data.count
          guard pendingBytes == 0 else { return 0 }
          defer { dropped = 0 }
          return dropped
        }
        if missed > 0 {
          write(Data("\(missed) log lines were not written: the disk fell behind\n".utf8))
        }
      }
    }

    /// Waits until every line handed in so far is written.
    public func flush() { queue.sync {} }

    /// Holds writing back, as a slow disk would; for tests.
    func pause() { queue.suspend() }
    func resume() { queue.resume() }

    private func write(_ data: Data) {
      guard !failed else { return }
      if descriptor < 0 { open() }
      guard descriptor >= 0 else { return }
      if size > 0, size + data.count > maximumFileBytes {
        Darwin.close(descriptor)
        descriptor = -1
        rotate()
        open()
        guard descriptor >= 0 else { return }
      }
      let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if written > 0 { size += written }
    }

    /// Opens the folder, never through a link, and the file in it. Anything
    /// unexpected stops writing: the log never writes through a link.
    private func open() {
      if folder < 0 {
        do {
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        } catch {
          failed = true
          return
        }
        let opened = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard opened >= 0, fstat(opened, &info) == 0, info.st_uid == geteuid() else {
          if opened >= 0 { Darwin.close(opened) }
          failed = true
          return
        }
        folder = opened
      }
      let opened = openat(
        folder, Self.fileName, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR)
      var info = stat()
      guard opened >= 0, fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == geteuid(), info.st_nlink == 1,
        info.st_mode & 0o777 == 0o600 || fchmod(opened, S_IRUSR | S_IWUSR) == 0
      else {
        if opened >= 0 { Darwin.close(opened) }
        failed = true
        return
      }
      descriptor = opened
      size = Int(info.st_size)
    }

    private func rotate() {
      func name(_ index: Int) -> String {
        index == 0 ? Self.fileName : "installer.\(index).log"
      }
      unlinkat(folder, name(Self.retainedFiles), 0)
      for index in stride(from: Self.retainedFiles - 1, through: 0, by: -1) {
        renameat(folder, name(index), folder, name(index + 1))
      }
    }
  }

  /// The app's Installer Log: every line this app and its helper logged since
  /// launch, for the log window, and the file it is appended to.
  @MainActor
  @Observable
  public final class InstallerLogStore {
    public static let defaultCapacity = 10_000
    public static let shared = InstallerLogStore()

    /// Where the process logs; see `InstallerLog.setProcessBuffer`.
    public nonisolated let buffer: InstallerLogBuffer
    public private(set) var entries: [InstallerLogEntry] = []
    /// Commands and transfers still under way, oldest first.
    public private(set) var running: [InstallerLogEntry] = []
    public private(set) var file: InstallerLogFile?
    private var open: [String: InstallerLogEntry] = [:]
    private var cursor: UInt64 = 0
    @ObservationIgnored private nonisolated let relay: Relay

    public init(capacity: Int = InstallerLogStore.defaultCapacity) {
      let relay = Relay()
      self.relay = relay
      buffer = InstallerLogBuffer(capacity: capacity) { relay.appended($0) }
      relay.store = self
    }

    /// Also appends every line, from now and the ones already kept, to `file`.
    public func persist(to file: InstallerLogFile, header: String = InstallerLogStore.header()) {
      file.append(line: header)
      for entry in buffer.snapshot() { file.append(entry) }
      relay.setFile(file)
      self.file = file
    }

    /// The first line of each launch in the persisted log.
    public nonisolated static func header(now: Date = Date()) -> String {
      var model = [CChar](repeating: 0, count: 64)
      var size = model.count
      let hardware =
        sysctlbyname("hw.model", &model, &size, nil, 0) == 0
        ? String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : "unknown Mac"
      let version = InstallerVersion.current().map { "\($0)" } ?? "unknown version"
      let system = ProcessInfo.processInfo.operatingSystemVersionString
      return "=== \(InstallerProductIdentity.appName) \(version) started "
        + "\(InstallerLogFormat.timestamp(now)) on \(hardware), macOS \(system) ==="
    }

    /// Reads the lines logged since the last refresh. Called on the main
    /// queue soon after a line is logged; tests call it directly.
    public func refresh() {
      let batch = buffer.entries(after: cursor, limit: .max, maximumBytes: .max)
      guard !batch.entries.isEmpty || batch.cursor != cursor else { return }
      cursor = batch.cursor
      entries.append(contentsOf: batch.entries)
      // Trim a quarter at a time, so the window rebuilds rarely, not per line.
      if entries.count > buffer.capacity + buffer.capacity / 4 {
        entries.removeFirst(entries.count - buffer.capacity)
      }
      var changed = false
      for entry in batch.entries {
        guard let activity = entry.activity else { continue }
        if entry.closesActivity {
          changed = open.removeValue(forKey: activity) != nil || changed
        } else if open[activity] == nil {
          open[activity] = entry
          changed = true
        }
      }
      if changed { running = open.values.sorted { $0.sequence < $1.sequence } }
    }

    /// Hands each line to the file and asks the store to refresh, at most
    /// once per main-queue turn. Never blocks the thread that logged.
    private final class Relay: @unchecked Sendable {
      weak var store: InstallerLogStore?
      private let lock = NSLock()
      private var file: InstallerLogFile?
      private var scheduled = false

      func setFile(_ file: InstallerLogFile) { lock.withLock { self.file = file } }

      func appended(_ entry: InstallerLogEntry) {
        let (file, schedule) = lock.withLock {
          defer { scheduled = true }
          return (self.file, !scheduled)
        }
        file?.append(entry)
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          lock.withLock { scheduled = false }
          MainActor.assumeIsolated { self.store?.refresh() }
        }
      }
    }
  }
#endif
