// SPDX-License-Identifier: MIT
// On Linux, URLSession and its request types live in FoundationNetworking and
// XMLParser in FoundationXML; Darwin's Foundation carries both.
import Foundation

#if canImport(FoundationNetworking)
  @_exported import FoundationNetworking
#endif
#if canImport(FoundationXML)
  @_exported import FoundationXML
#endif

#if os(Linux)
  // Linux has no URLSession.bytes(for:delegate:). A harness never opens a
  // connection; this keeps the transport source compiling as it is.
  extension URLSession {
    struct FuzzNoBytes: AsyncSequence {
      typealias Element = UInt8
      struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> UInt8? { nil }
      }
      func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
    }
    func bytes(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws
      -> (FuzzNoBytes, URLResponse)
    {
      throw URLError(.notConnectedToInternet)
    }
  }
#endif
