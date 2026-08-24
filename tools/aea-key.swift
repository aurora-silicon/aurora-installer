// SPDX-License-Identifier: MIT
//
// Copyright (c) 2024 Dhinak G
// Copyright (c) 2026 Aurora Silicon contributors
//
// AEA auth-data parsing and the HPKE parameters are based on dhinakg/aeota
// commit 53e461d9788744bdd107e7d2043d71625324a682 (MIT).

import CryptoKit
import Foundation

enum AEAKeyError: Error, CustomStringConvertible {
    case usage
    case invalidArchive(String)
    case invalidKeyResponse(String)
    case unsafeURL(String)
    case outputExists(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: aea-key input.dmg.aea output.key"
        case .invalidArchive(let message):
            return "invalid AEA archive: \(message)"
        case .invalidKeyResponse(let message):
            return "invalid WKMS response: \(message)"
        case .unsafeURL(let value):
            return "refusing unexpected WKMS URL: \(value)"
        case .outputExists(let path):
            return "refusing to overwrite key file: \(path)"
        }
    }
}

private func littleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw AEAKeyError.invalidArchive("truncated integer")
    }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func readAuthData(_ path: String) throws -> [String: Data] {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }

    guard let header = try handle.read(upToCount: 12), header.count == 12 else {
        throw AEAKeyError.invalidArchive("truncated header")
    }
    guard header.prefix(4) == Data("AEA1".utf8) else {
        throw AEAKeyError.invalidArchive("bad magic")
    }

    let profile = UInt32(header[4]) | (UInt32(header[5]) << 8) | (UInt32(header[6]) << 16)
    guard profile == 1 else {
        throw AEAKeyError.invalidArchive("unsupported profile \(profile)")
    }

    let authSize = Int(try littleEndianUInt32(header, at: 8))
    guard authSize > 0, authSize <= 1024 * 1024 else {
        throw AEAKeyError.invalidArchive("unexpected auth-data size \(authSize)")
    }
    guard let blob = try handle.read(upToCount: authSize), blob.count == authSize else {
        throw AEAKeyError.invalidArchive("truncated auth data")
    }

    var fields: [String: Data] = [:]
    var offset = 0
    while offset < blob.count {
        let fieldSize = Int(try littleEndianUInt32(blob, at: offset))
        guard fieldSize >= 6, offset + fieldSize <= blob.count else {
            throw AEAKeyError.invalidArchive("invalid auth-data field size")
        }

        let field = blob[(offset + 4)..<(offset + fieldSize)]
        guard let separator = field.firstIndex(of: 0) else {
            throw AEAKeyError.invalidArchive("auth-data field has no key terminator")
        }
        guard let key = String(data: field[..<separator], encoding: .utf8), !key.isEmpty else {
            throw AEAKeyError.invalidArchive("invalid auth-data key")
        }
        fields[key] = Data(field[field.index(after: separator)...])
        offset += fieldSize
    }
    return fields
}

private func fetchPrivateKey(_ rawURL: Data) throws -> Data {
    guard let value = String(data: rawURL, encoding: .utf8), let url = URL(string: value) else {
        throw AEAKeyError.invalidArchive("invalid FCS key URL")
    }
    guard url.scheme == "https", url.host == "wkms-public.apple.com", url.user == nil,
          url.password == nil, url.port == nil else {
        throw AEAKeyError.unsafeURL(value)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(error)
            return
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let data, data.count > 0, data.count <= 64 * 1024 else {
            result = .failure(AEAKeyError.invalidKeyResponse("unexpected HTTP response"))
            return
        }
        result = .success(data)
    }.resume()

    guard semaphore.wait(timeout: .now() + 20) == .success, let result else {
        throw AEAKeyError.invalidKeyResponse("request timed out")
    }
    return try result.get()
}

private func unwrapKey(fields: [String: Data]) throws -> Data {
    guard let rawURL = fields["com.apple.wkms.fcs-key-url"] else {
        throw AEAKeyError.invalidArchive("missing FCS key URL")
    }
    guard let rawResponse = fields["com.apple.wkms.fcs-response"] else {
        throw AEAKeyError.invalidArchive("missing FCS response")
    }

    guard let object = try JSONSerialization.jsonObject(with: rawResponse) as? [String: Any],
          let encodedRequest = object["enc-request"] as? String,
          let encodedWrappedKey = object["wrapped-key"] as? String,
          let encryptedRequest = Data(base64Encoded: encodedRequest),
          let wrappedKey = Data(base64Encoded: encodedWrappedKey) else {
        throw AEAKeyError.invalidArchive("malformed FCS response")
    }
    guard wrappedKey.count == 48 else {
        throw AEAKeyError.invalidArchive("unexpected wrapped-key size")
    }

    let privateKeyData = try fetchPrivateKey(rawURL)
    guard let privateKeyPEM = String(data: privateKeyData, encoding: .utf8) else {
        throw AEAKeyError.invalidKeyResponse("private key is not PEM text")
    }
    let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: privateKeyPEM)
    var recipient = try HPKE.Recipient(
        privateKey: privateKey,
        ciphersuite: .P256_SHA256_AES_GCM_256,
        info: Data(),
        encapsulatedKey: encryptedRequest
    )
    return try recipient.open(wrappedKey)
}

private func writeKey(_ key: Data, to path: String) throws {
    guard !FileManager.default.fileExists(atPath: path) else {
        throw AEAKeyError.outputExists(path)
    }
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    guard FileManager.default.createFile(atPath: path, contents: key, attributes: attributes) else {
        throw AEAKeyError.invalidKeyResponse("could not create key file")
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw AEAKeyError.usage
    }
    let fields = try readAuthData(CommandLine.arguments[1])
    let key = try unwrapKey(fields: fields)
    guard key.count == 32 else {
        throw AEAKeyError.invalidKeyResponse("unexpected unwrapped key size")
    }
    try writeKey(key, to: CommandLine.arguments[2])
} catch {
    FileHandle.standardError.write(Data("aea-key: \(error)\n".utf8))
    exit(1)
}
