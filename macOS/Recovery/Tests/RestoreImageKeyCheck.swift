import Foundation

// RestoreImageKey against two independent references: the restore image
// helper's Go-generated vectors (RestoreImage/Tests/.../go-vectors.json, the
// same ones its CryptoKit unwrap passes) and pyca/cryptography vectors
// (Fixtures/RestoreImageKey, generate.py). Every key in both is disposable.
@main struct Check {
  nonisolated(unsafe) static var failures = 0
  static func expect(_ condition: Bool, _ what: String) {
    if !condition {
      failures += 1
      print("FAIL: \(what)")
    }
  }
  static func expectThrows(
    _ what: String, _ failure: RestoreImageKey.Failure, _ body: () throws -> Void
  ) {
    do {
      try body()
      expect(false, "\(what): no error")
    } catch let error as RestoreImageKey.Failure {
      expect(error == failure, "\(what): \(error), expected \(failure)")
    } catch {
      expect(false, "\(what): \(error)")
    }
  }
  static func data(_ text: String?) -> Data { Data(base64Encoded: text ?? "") ?? Data([0xff]) }
  static func response(_ enc: String, _ wrapped: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["enc-request": enc, "wrapped-key": wrapped])
  }

  static func main() throws {
    let here = URL(fileURLWithPath: "Tests/Fixtures/RestoreImageKey/vectors.json")
    let go = URL(
      fileURLWithPath: "../RestoreImage/Tests/RestoreImageCoreTests/Fixtures/go-vectors.json")
    let v =
      try JSONSerialization.jsonObject(with: Data(contentsOf: here)) as! [String: [[String: Any]]]
    let g = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: go))

    // Go reference: the unwrap and the AEA key schedule's HKDF.
    let goPEM = Data(g["pem"]!.utf8)
    expect(
      (try? RestoreImageKey.unwrap(
        fcsResponse: response(g["enc"]!, g["wrapped"]!), releaseKey: goPEM)) == data(g["key"]),
      "Go HPKE unwrap")
    var forged = [UInt8](data(g["wrapped"]))
    forged[47] ^= 0x80
    expectThrows("Go forged tag", .authentication) {
      _ = try RestoreImageKey.unwrap(
        fcsResponse: response(g["enc"]!, Data(forged).base64EncodedString()), releaseKey: goPEM)
    }
    expect(
      (try? RestoreImageKey.derive(
        data(g["key"]), salt: Data("salt".utf8), info: Data("AEA_RHEK".utf8), size: 80))
        == data(g["hkdf"]),
      "Go HKDF")

    // pyca HPKE: PKCS#8 with and without the embedded public key.
    for (index, item) in v["hpke"]!.enumerated() {
      let pem = Data((item["pem"] as! String).utf8)
      let enc = item["enc"] as! String
      let wrapped = item["wrapped"] as! String
      let key = try? RestoreImageKey.PrivateKey(pem: pem)
      expect(
        key?.publicKeyRepresentation == data(item["public"] as? String), "hpke \(index) public")
      expect(
        (try? RestoreImageKey.unwrap(fcsResponse: response(enc, wrapped), releaseKey: pem))
          == data(item["key"] as? String),
        "hpke \(index) unwrap")
      let metadata = ["com.apple.wkms.fcs-response": response(enc, wrapped)]
      expect(
        (try? RestoreImageKey.unwrap(metadata, releaseKey: pem)) == data(item["key"] as? String),
        "hpke \(index) metadata unwrap")
      // Another recipient's key, a changed encapsulation, a point off the curve.
      let other = Data((v["hpke"]![(index + 1) % v["hpke"]!.count]["pem"] as! String).utf8)
      expectThrows("hpke \(index) wrong key", .authentication) {
        _ = try RestoreImageKey.unwrap(fcsResponse: response(enc, wrapped), releaseKey: other)
      }
      var bent = [UInt8](data(enc))
      bent[64] ^= 1
      expectThrows("hpke \(index) off-curve enc", .invalidPoint) {
        _ = try RestoreImageKey.unwrap(
          fcsResponse: response(Data(bent).base64EncodedString(), wrapped), releaseKey: pem)
      }
    }

    // pyca P-256: d*G for edge and random scalars.
    for (index, item) in v["points"]!.enumerated() {
      let scalar = [UInt8](data(item["scalar"] as? String))
      expect(
        (try? RestoreImageKey.PrivateKey(scalar: scalar))?.publicKeyRepresentation
          == data(item["public"] as? String),
        "point \(index)")
    }
    let order = [UInt8](
      Data(base64Encoded: "/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVE=")!)
    expectThrows("scalar zero", .invalidPrivateKey) {
      _ = try RestoreImageKey.PrivateKey(scalar: [UInt8](repeating: 0, count: 32))
    }
    expectThrows("scalar n", .invalidPrivateKey) {
      _ = try RestoreImageKey.PrivateKey(scalar: order)
    }

    // pyca AES-256-GCM and HKDF-SHA256.
    for (index, item) in v["gcm"]!.enumerated() {
      let key = [UInt8](data(item["key"] as? String))
      let nonce = [UInt8](data(item["nonce"] as? String))
      var sealed = [UInt8](data(item["sealed"] as? String))
      expect(
        (try? RestoreImageKey.GCM.open(key: key, nonce: nonce, sealed: sealed))
          == [UInt8](data(item["plain"] as? String)),
        "gcm \(index)")
      sealed[0] ^= 1
      expectThrows("gcm \(index) changed", .authentication) {
        _ = try RestoreImageKey.GCM.open(key: key, nonce: nonce, sealed: sealed)
      }
    }
    for (index, item) in v["hkdf"]!.enumerated() {
      expect(
        (try? RestoreImageKey.derive(
          data(item["ikm"] as? String), salt: data(item["salt"] as? String),
          info: data(item["info"] as? String), size: item["size"] as! Int))
          == data(item["okm"] as? String),
        "hkdf \(index)")
    }

    // PEM and response admission.
    let pem = v["hpke"]![0]["pem"] as! String
    expectThrows("not PEM", .invalidPrivateKey) {
      _ = try RestoreImageKey.PrivateKey(pem: Data("hello".utf8))
    }
    expectThrows("truncated DER", .invalidPrivateKey) {
      let body = pem.split(separator: "\n").dropFirst().dropLast().joined()
      let short = Data(base64Encoded: body)!.dropLast(1).base64EncodedString()
      _ = try RestoreImageKey.PrivateKey(
        pem: Data("-----BEGIN PRIVATE KEY-----\n\(short)\n-----END PRIVATE KEY-----".utf8))
    }
    expectThrows("public key of another scalar", .invalidPrivateKey) {
      // Swap in hpke[2]'s public key (hpke[0] and hpke[2] both embed one).
      let body = pem.split(separator: "\n").dropFirst().dropLast().joined()
      var der = [UInt8](Data(base64Encoded: body)!)
      let mine = [UInt8](data(v["hpke"]![0]["public"] as? String))
      let theirs = [UInt8](data(v["hpke"]![2]["public"] as? String))
      let at = (0...(der.count - 65)).first { Array(der[$0..<($0 + 65)]) == mine }!
      der.replaceSubrange(at..<(at + 65), with: theirs)
      _ = try RestoreImageKey.PrivateKey(
        pem: Data(
          "-----BEGIN PRIVATE KEY-----\n\(Data(der).base64EncodedString())\n-----END PRIVATE KEY-----"
            .utf8))
    }
    let item = v["hpke"]![0]
    let enc = item["enc"] as! String
    let wrapped = item["wrapped"] as! String
    expectThrows("short wrapped key", .invalidResponse) {
      _ = try RestoreImageKey.unwrap(
        fcsResponse: response(enc, data(wrapped).dropLast().base64EncodedString()),
        releaseKey: Data(pem.utf8))
    }
    expectThrows("no response", .invalidResponse) {
      _ = try RestoreImageKey.unwrap([:], releaseKey: Data(pem.utf8))
    }
    expectThrows("non-canonical base64", .invalidResponse) {
      _ = try RestoreImageKey.unwrap(
        fcsResponse: response(enc, "\n" + wrapped), releaseKey: Data(pem.utf8))
    }

    // AEA metadata: the same parser shape as the restore image helper.
    func archive(_ entries: [(String, String)]) -> Data {
      var body = Data()
      for (key, value) in entries {
        let entry = Data(key.utf8) + [0] + Data(value.utf8)
        withUnsafeBytes(of: UInt32(entry.count + 4).littleEndian) { body += $0 }
        body += entry
      }
      var out = Data("AEA1".utf8)
      withUnsafeBytes(of: UInt32(1).littleEndian) { out += $0 }
      withUnsafeBytes(of: UInt32(body.count).littleEndian) { out += $0 }
      return out + body + Data(repeating: 0xaa, count: 16)
    }
    let url = "https://wkms-public.apple.com/fcs-keys/" + String(repeating: "A", count: 43) + "="
    let md = try RestoreImageKey.metadata(
      archive([("com.apple.wkms.fcs-key-url", url), ("com.apple.wkms.fcs-response", "{}")]))
    expect((try? RestoreImageKey.keyURL(md))?.absoluteString == url, "metadata key URL")
    expectThrows("duplicate metadata key", .invalidArchive) {
      _ = try RestoreImageKey.metadata(archive([("a", "1"), ("a", "2")]))
    }
    for other in [
      "https://example.com/fcs-keys/" + String(repeating: "A", count: 43) + "=",
      url + "/", url.replacingOccurrences(of: "https", with: "http"),
    ] {
      expectThrows("key URL \(other)", .invalidArchive) {
        _ = try RestoreImageKey.keyURL(
          RestoreImageKey.metadata(archive([("com.apple.wkms.fcs-key-url", other)])))
      }
    }
    expectThrows("http key URL", .invalidArchive) {
      _ = try RestoreImageKey.keyURL(
        RestoreImageKey.metadata(archive([("com.apple.wkms.fcs-key-url", "http://x/y")])))
    }
    expectThrows("truncated metadata", .invalidArchive) {
      _ = try RestoreImageKey.metadata(archive([("a", "1")]).prefix(15))
    }
    expectThrows("wrong profile", .invalidArchive) {
      var bad = archive([("a", "1")])
      bad[4] = 2
      _ = try RestoreImageKey.metadata(bad)
    }

    // Go reference AEA: its prefix (header, metadata, salt, root header)
    // authenticates under its archive key, and under no other.
    let aea =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: URL(
            fileURLWithPath: "../RestoreImage/Tests/RestoreImageCoreTests/Fixtures/go-aea.json")))
      as! [String: Any]
    let archiveKey = data(aea["key"] as? String)
    let records = aea["records"] as! [[String: Any]]
    let prefix = records.first { ($0["record"] as! [String: Any])["offset"] as? Int == 0 }!
    let head = data(prefix["data"] as? String)
    expect(
      (try? RestoreImageKey.authenticateRoot(head, archiveKey: archiveKey)) != nil, "Go AEA root")
    var otherKey = [UInt8](archiveKey)
    otherKey[0] ^= 1
    expectThrows("Go AEA root, other key", .authentication) {
      try RestoreImageKey.authenticateRoot(head, archiveKey: Data(otherKey))
    }
    for index in [12, head.count - 1] {
      var changed = head
      changed[index] ^= 1
      expectThrows("Go AEA root, byte \(index) changed", .authentication) {
        try RestoreImageKey.authenticateRoot(changed, archiveKey: archiveKey)
      }
    }
    expectThrows("Go AEA root, short", .invalidArchive) {
      try RestoreImageKey.authenticateRoot(head.prefix(head.count - 1), archiveKey: archiveKey)
    }

    if failures > 0 { exit(1) }
    print("restore-image-key: all checks passed")
  }
}
