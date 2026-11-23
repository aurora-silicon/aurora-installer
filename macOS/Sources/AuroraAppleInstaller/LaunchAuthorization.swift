#if os(macOS)
  import Foundation
  import Security

  /// An authorization holding one right, freed when it goes away. The silent
  /// route pre-authorizes with the credentials the person just typed and
  /// never allows interaction; the dialog route lets macOS show its own
  /// administrator dialog.
  final class LaunchAuthorization: @unchecked Sendable {
    let reference: AuthorizationRef

    private init(_ reference: AuthorizationRef) { self.reference = reference }
    deinit { AuthorizationFree(reference, []) }

    struct NotAuthorized: Error {
      let value: InstallerHelperBlessResult
    }

    static func authorize(
      right: String,
      credentials: MachineOwnerAuthorization?,
      allowingDialog: Bool
    ) -> Result<LaunchAuthorization, NotAuthorized> {
      var reference: AuthorizationRef?
      guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess,
        let reference
      else {
        return .failure(NotAuthorized(value: .failed("AuthorizationCreate failed")))
      }
      let rights = LaunchAuthorization(reference)
      let status = copyRight(
        right, into: reference, credentials: credentials, allowingDialog: allowingDialog)
      switch status {
      case errAuthorizationSuccess:
        return .success(rights)
      case errAuthorizationDenied, errAuthorizationInteractionNotAllowed:
        return .failure(NotAuthorized(value: .refused))
      case errAuthorizationCanceled:
        return .failure(NotAuthorized(value: .cancelled))
      default:
        return .failure(
          NotAuthorized(value: .failed("AuthorizationCopyRights returned \(status)")))
      }
    }

    /// Requests the right. With credentials, they go in the authorization
    /// environment and are wiped from memory before returning.
    private static func copyRight(
      _ right: String,
      into reference: AuthorizationRef,
      credentials: MachineOwnerAuthorization?,
      allowingDialog: Bool
    ) -> OSStatus {
      var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
      if allowingDialog {
        flags.insert(.interactionAllowed)
      }
      return right.withCString { rightName in
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { itemPointer in
          var rights = AuthorizationRights(count: 1, items: itemPointer)
          guard let credentials else {
            return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
          }
          return withEnvironment(credentials) { environment in
            AuthorizationCopyRights(reference, &rights, environment, flags, nil)
          }
        }
      }
    }

    private static func withEnvironment(
      _ credentials: MachineOwnerAuthorization,
      _ body: (UnsafePointer<AuthorizationEnvironment>) -> OSStatus
    ) -> OSStatus {
      let username = Array(credentials.username.utf8CString)
      var password = [CChar](repeating: 0, count: credentials.password.count + 1)
      credentials.password.withUnsafeBytes { bytes in
        for (index, byte) in bytes.enumerated() {
          password[index] = CChar(bitPattern: byte)
        }
      }
      defer {
        for index in password.indices {
          password[index] = 0
        }
      }
      return username.withUnsafeBufferPointer { usernameBytes in
        password.withUnsafeMutableBufferPointer { passwordBytes in
          kAuthorizationEnvironmentUsername.withCString { usernameKey in
            kAuthorizationEnvironmentPassword.withCString { passwordKey in
              var items = [
                AuthorizationItem(
                  name: usernameKey,
                  valueLength: usernameBytes.count - 1,
                  value: UnsafeMutableRawPointer(mutating: usernameBytes.baseAddress),
                  flags: 0),
                AuthorizationItem(
                  name: passwordKey,
                  valueLength: passwordBytes.count - 1,
                  value: UnsafeMutableRawPointer(passwordBytes.baseAddress),
                  flags: 0),
              ]
              return items.withUnsafeMutableBufferPointer { itemBytes in
                var environment = AuthorizationEnvironment(
                  count: UInt32(itemBytes.count), items: itemBytes.baseAddress)
                return body(&environment)
              }
            }
          }
        }
      }
    }
  }
#endif
