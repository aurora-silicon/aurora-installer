#if os(macOS)
  import AuroraFirmware
  import Foundation

  /// This Mac's N1 Wi-Fi and Bluetooth firmware, made from the stub's restore
  /// files. It runs after the stub is on disk, so it never stops the install:
  /// a Mac whose N1 firmware can't be made installs without Wi-Fi and
  /// Bluetooth, and the Installer Log says why in one line.
  enum NativeCentauriFirmware {
    struct Prepared: Equatable, Sendable {
      /// The file for `vendorfw/`, under the name the driver requests.
      let package: [String: Data]
      /// Its inputs, for `asahi/all_firmware.tar.gz`.
      let fallback: [String: Data]
    }

    enum Problem: Error, Equatable {
      case missing(String)
      case unreadable(String)

      var reason: String {
        switch self {
        case .missing(let path): "the startup firmware has no \(path)"
        case .unreadable(let path): "\(path) can't be read or isn't the file the installer copied"
        }
      }
    }

    /// `read` returns a file of the stub's restore directory by its path
    /// there, or nil when the stub copied no file at that path. Only
    /// cancellation is thrown; every other failure is logged and gives nil.
    static func prepare(
      _ source: NativeFirmwareSourcePlan, read: (String, Int) throws -> Data?
    ) throws -> Prepared? {
      let reason: String
      if let centauri = source.centauri {
        do {
          let image = try input(centauri.image, CentauriFirmware.maximumBytes, read)
          let ticket = try input(centauri.ticket, CentauriFirmware.maximumTicketBytes, read)
          let firmware = try CentauriFirmware.personalize(image: image, ticket: ticket)
          let fallback = CentauriFirmware.fallback(
            machine: source.machine, image: image, ticket: ticket)
          return Prepared(package: [centauri.name: firmware], fallback: fallback)
        } catch is CancellationError {
          throw CancellationError()
        } catch let problem as Problem {
          reason = problem.reason
        } catch let failure as RestoreFailure {
          var message = failure.message
          if message.hasSuffix(".") { message.removeLast() }
          reason = message.prefix(1).lowercased() + message.dropFirst()
        } catch {
          reason = String(describing: error)
        }
      } else if let unavailable = source.centauriProblem {
        reason = unavailable
      } else {
        return nil
      }
      InstallerLog.error(line(reason))
      return nil
    }

    static func line(_ reason: String) -> String {
      "N1 Wi-Fi/Bluetooth firmware could not be prepared: \(reason); "
        + "installing without Wi-Fi and Bluetooth"
    }

    private static func input(
      _ path: String, _ maximum: Int, _ read: (String, Int) throws -> Data?
    ) throws -> Data {
      let data: Data?
      do {
        data = try read(path, maximum)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw Problem.unreadable(path)
      }
      guard let data else { throw Problem.missing(path) }
      return data
    }
  }
#endif
