import Foundation

// RestoreImageKey against published known answers (RFC 5869 A.1-A.3, the
// CFRG HPKE test vector for this suite, NIST CAVP gcmDecrypt256) and two
// independent implementations: the restore image helper's Go-generated vectors
// (RestoreImage/Tests/.../go-vectors.json, the same ones its CryptoKit unwrap
// passes) and pyca/cryptography vectors (Fixtures/RestoreImageKey,
// generate.py). Every key in them is disposable.
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
  static func hex(_ text: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      out.append(UInt8(text[index..<next], radix: 16)!)
      index = next
    }
    return out
  }

  /// RFC 5869 Appendix A.1-A.3 (HKDF-SHA256).
  static func rfc5869() {
    let cases: [(ikm: [UInt8], salt: [UInt8], info: [UInt8], okm: String)] = [
      (
        [UInt8](repeating: 0x0b, count: 22), Array(0x00...0x0c), Array(0xf0...0xf9),
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
      ),
      (
        Array(0x00...0x4f), Array(0x60...0xaf), Array(0xb0...0xff),
        "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
          + "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
          + "cc30c58179ec3e87c14c01d5c1f3434f1d87"
      ),
      (
        [UInt8](repeating: 0x0b, count: 22), [], [],
        "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
      ),
    ]
    for (index, item) in cases.enumerated() {
      let okm = hex(item.okm)
      expect(
        (try? RestoreImageKey.derive(
          Data(item.ikm), salt: Data(item.salt), info: Data(item.info), size: okm.count))
          == Data(okm), "RFC 5869 A.\(index + 1)")
    }
  }

  /// The CFRG HPKE test vector for mode 0, DHKEM(P-256, HKDF-SHA256),
  /// HKDF-SHA256, AES-256-GCM (draft-irtf-cfrg-hpke test-vectors.json; this
  /// suite isn't in RFC 9180's appendix), sequence 0.
  static func cfrgHPKE() {
    let skRm = hex("317f915db7bc629c48fe765587897e01e282d3e8445f79f27f65d031a88082b2")
    let pkRm = hex(
      "04abc7e49a4c6b3566d77d0304addc6ed0e98512ffccf505e6a8e3eb25c685136f"
        + "853148544876de76c0f2ef99cdc3a05ccf5ded7860c7c021238f9e2073d2356c")
    let enc = hex(
      "04c06b4f6bebc7bb495cb797ab753f911aff80aefb86fd8b6fcc35525f3ab5f03e"
        + "0b21bd31a86c6048af3cb2d98e0d3bf01da5cc4c39ff5370d331a4f1f7d5a4e0")
    let info = hex("4f6465206f6e2061204772656369616e2055726e")
    let ct0 = hex(
      "58c61a45059d0c5704560e9d88b564a8b63f1364b8d1fcb3c4c6ddc1d291742465e902cd216f8908da49f8f96f")
    let ct1 = hex(
      "b4e7c90d1dd62cb563694956eb517ab55d5e7d1f6366a0066c04ababaa444dbaf60a30d7bb7d3e91b969762dee")
    let pt = hex("4265617574792069732074727574682c20747275746820626561757479")
    guard let key = try? RestoreImageKey.PrivateKey(scalar: skRm, publicKey: pkRm) else {
      return expect(false, "CFRG HPKE key pair")
    }
    expect(
      (try? RestoreImageKey.open(
        key, encapsulated: enc, ciphertext: ct0, info: info, aad: Array("Count-0".utf8))) == pt,
      "CFRG HPKE open")
    // Sequence 1's ciphertext under sequence 0's nonce, and a changed info.
    expectThrows("CFRG HPKE seq 1 at seq 0", .authentication) {
      _ = try RestoreImageKey.open(
        key, encapsulated: enc, ciphertext: ct1, info: info, aad: Array("Count-1".utf8))
    }
    expectThrows("CFRG HPKE other info", .authentication) {
      _ = try RestoreImageKey.open(
        key, encapsulated: enc, ciphertext: ct0, info: [], aad: Array("Count-0".utf8))
    }
  }

  /// NIST CAVP gcmDecrypt256.rsp (gcmtestvectors.zip), 96-bit IV, 128-bit
  /// tag: no AAD with PTlen 0/128/408, then PTlen 128 with AADlen 160 and 384
  /// (partial and whole AAD blocks); `nil` plaintext is a case marked FAIL.
  static func nistGCM() {
    let cases: [(key: String, iv: String, ct: String, tag: String, pt: String?, aad: String)] = [
      (
        "f5a2b27c74355872eb3ef6c5feafaa740e6ae990d9d48c3bd9bb8235e589f010",
        "58d2240f580a31c1d24948e9", "", "15e051a5e4a5f5da6cea92e2ebee5bac", "", ""
      ),
      (
        "e5a8123f2e2e007d4e379ba114a2fb66e6613f57c72d4e4f024964053028a831",
        "51e43385bf533e168427e1ad", "", "38fe845c66e66bdd884c2aecafd280e6", nil, ""
      ),
      (
        "4c8ebfe1444ec1b2d503c6986659af2c94fafe945f72c1e8486a5acfedb8a0f8",
        "473360e0ad24889959858995", "d2c78110ac7e8f107c0df0570bd7c90c",
        "c26a379b6d98ef2852ead8ce83a833a7", "7789b41cb3ee548814ca0b388c10b343", ""
      ),
      (
        "c997768e2d14e3d38259667a6649079de77beb4543589771e5068e6cd7cd0b14",
        "835090aed9552dbdd45277e2", "9f6607d68e22ccf21928db0986be126e",
        "f32617f67c574fd9f44ef76ff880ab9f", nil, ""
      ),
      (
        "4433db5fe066960bdd4e1d4d418b641c14bfcef9d574e29dcd0995352850f1eb",
        "0e396446655582838f27f72f",
        "b0d254abe43bdb563ead669192c1e57e9a85c51dba0f1c8501d1ce92273f1ce7e140dcfac94757fabb128caad16912cead0607",
        "ffd0b02c92dbfcfbe9d58f7ff9e6f506",
        "d602c06b947abe06cf6aa2c5c1562e29062ad6220da9bc9c25d66a60bd85a80d4fbcc1fb4919b6566be35af9819aba836b8b47",
        ""
      ),
      (
        "28ae911ee685872d906de12d7696351df8ef2234a74a95efa4ea15b327338fe0",
        "2fe6a815d4865181fade5fac",
        "1168442ef64656ef6577fb42c1919c84aae856388e4db9945bb8c9b8412bbe6458bc400444d5d2bf2630f83468f66f9e46e790",
        "b75f616fd1a3d6563b62b899e5a7e522", nil, ""
      ),
      (
        "aef220035cbb9e47ce605698aa28e3b0ba50b4ffcd473bb8da2017889b38055f",
        "cde7af095360ea827778761d", "bb1cdf25717445e5a77444d488387aee",
        "e72340deabc1589125e9e4a2755512c7", "9775db638e5d964fc9c70b5fe456ec14",
        "f269837306abbcee2da1722f28be35163e3d8567"
      ),
      (
        "041ef9cd359ac65b7937dcee46778d19dc32a312c81edc15dbc8918df75081f0",
        "4bf5a7c50201a6586b1dcdb5", "2c24ef09b6a01b5f200c59284316fa56",
        "36c2da827d58cdc8cd3faf0a335b1846", nil, "10980f54fdbd18e49a48cf74ecbbb7e9d22083a3"
      ),
      (
        "16ac8e71760c1fd4eba37422bcbcaaf67513fe6822d00a14e3ab62a6ca559931",
        "7021d16596de09585b50673a", "073988485ae13dddb025f7f07059ca70",
        "241a2bc57f4ee159a79bc57cf48e023c", "5ddecdab11e715d0b5996d46cb18715a",
        "ecdca487c04e574ff11acec743c66e052e80bbc7fe67273246e218e8c82de0e6"
          + "91dcf4945572a2195b57c2257d2c8f41"
      ),
      (
        "0fc8ae600fd3396716c3e88327545b5e4308eda1c25e076d1098fabb74a9f0a0",
        "c529787b4c756a2343f36280", "7dc464c2735f446f9a3f92873688e6c3",
        "fd6d32ff9a090bb880371a678f37ecaa", nil,
        "2c6ac22d787b70bf516f4bf72deb8f9514a588e5e53cb26980becd0d500bb234"
          + "53d8ed874ec2514b813aa45d2dc36e6a"
      ),
    ]
    for (index, item) in cases.enumerated() {
      let opened = { () throws -> [UInt8] in
        try RestoreImageKey.GCM.open(
          key: hex(item.key), nonce: hex(item.iv), sealed: hex(item.ct) + hex(item.tag),
          aad: hex(item.aad))
      }
      if let pt = item.pt {
        expect((try? opened()) == hex(pt), "NIST GCM \(index)")
      } else {
        expectThrows("NIST GCM \(index) (FAIL)", .authentication) { _ = try opened() }
      }
    }
  }
  static func response(_ enc: String, _ wrapped: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["enc-request": enc, "wrapped-key": wrapped])
  }

  static func main() throws {
    rfc5869()
    cfrgHPKE()
    nistGCM()

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
    // A changed ciphertext byte (the wrapped key's first and last, not the tag).
    for index in [0, 31] {
      var bent = [UInt8](data(g["wrapped"]))
      bent[index] ^= 1
      expectThrows("Go ciphertext byte \(index)", .authentication) {
        _ = try RestoreImageKey.unwrap(
          fcsResponse: response(g["enc"]!, Data(bent).base64EncodedString()), releaseKey: goPEM)
      }
    }
    // Encapsulated keys that aren't an uncompressed point of the curve with
    // coordinates below p: hybrid (0x06/0x07), the point at infinity, (0, 0),
    // x = p for the curve point (0, y0), y = 2^256 - 1. (0, y0) itself is a
    // curve point, so it is admitted and only fails to authenticate.
    let goKey = try RestoreImageKey.PrivateKey(pem: goPEM)
    let goEnc = [UInt8](data(g["enc"]))
    let goSealed = [UInt8](data(g["wrapped"]))
    let y0 = hex("66485c780e2f83d72433bd5d84a06bb6541c2af31dae871728bf856a174f93f4")
    let zeroX = [UInt8](repeating: 0, count: 32)
    let p = RestoreImageKey.PrivateKey.prime
    let tail = Array(goEnc.dropFirst())
    let ones = [UInt8](repeating: 0xff, count: 32)
    var badPoints: [(String, [UInt8])] = []
    badPoints.append(("hybrid 0x06", [0x06] + tail))
    badPoints.append(("hybrid 0x07", [0x07] + tail))
    badPoints.append(("infinity", [0x00]))
    badPoints.append(("(0, 0)", [0x04] + zeroX + zeroX))
    badPoints.append(("x = p", [0x04] + p + y0))
    badPoints.append(("y = 2^256 - 1", [0x04] + zeroX + ones))
    badPoints.append(("y = p", [0x04] + Array(goEnc[1..<33]) + p))
    // The coordinate range is checked here, not left to the ECDH backend.
    let pMinus1 = Array(p.dropLast()) + [p[31] - 1]
    expect(
      RestoreImageKey.PrivateKey.canonical([0x04] + pMinus1 + pMinus1), "x, y = p - 1 admitted")
    expect(!RestoreImageKey.PrivateKey.canonical([0x04] + p + y0), "x = p refused before ECDH")
    expect(!RestoreImageKey.PrivateKey.canonical([0x04] + y0 + p), "y = p refused before ECDH")
    for (what, enc) in badPoints {
      expectThrows("enc \(what)", .invalidPoint) {
        _ = try RestoreImageKey.open(goKey, encapsulated: enc, ciphertext: goSealed, info: [])
      }
    }
    expectThrows("enc (0, y0) is a curve point", .authentication) {
      _ = try RestoreImageKey.open(
        goKey, encapsulated: [0x04] + zeroX + y0, ciphertext: goSealed, info: [])
    }

    // pyca HPKE. Even entries are PKCS#8 with the embedded public key and
    // open from the PEM; odd ones omit it, so the PEM is refused and the
    // pair is built from the vector's public key instead.
    let hpke = v["hpke"]!
    for (index, item) in hpke.enumerated() {
      let pem = Data((item["pem"] as! String).utf8)
      let enc = item["enc"] as! String
      let wrapped = item["wrapped"] as! String
      let expected = data(item["key"] as? String)
      let scalar = [UInt8](data(item["scalar"] as? String))
      let pair = try? RestoreImageKey.PrivateKey(
        scalar: scalar, publicKey: [UInt8](data(item["public"] as? String)))
      expect(pair != nil, "hpke \(index) key pair")
      if let pair {
        expect(
          (try? RestoreImageKey.open(
            pair, encapsulated: [UInt8](data(enc)), ciphertext: [UInt8](data(wrapped)), info: []))
            == [UInt8](expected), "hpke \(index) open")
      }
      guard index % 2 == 0 else {
        expectThrows("hpke \(index) PEM without public key", .invalidPrivateKey) {
          _ = try RestoreImageKey.PrivateKey(pem: pem)
        }
        continue
      }
      let key = try? RestoreImageKey.PrivateKey(pem: pem)
      expect(
        key?.publicKeyRepresentation == data(item["public"] as? String), "hpke \(index) public")
      expect(
        (try? RestoreImageKey.unwrap(fcsResponse: response(enc, wrapped), releaseKey: pem))
          == expected,
        "hpke \(index) unwrap")
      let metadata = ["com.apple.wkms.fcs-response": response(enc, wrapped)]
      expect(
        (try? RestoreImageKey.unwrap(metadata, releaseKey: pem)) == expected,
        "hpke \(index) metadata unwrap")
      // Another recipient's key, a point off the curve, a compressed point.
      let other = Data((hpke[(index + 2) % hpke.count]["pem"] as! String).utf8)
      expectThrows("hpke \(index) wrong key", .authentication) {
        _ = try RestoreImageKey.unwrap(fcsResponse: response(enc, wrapped), releaseKey: other)
      }
      var bent = [UInt8](data(enc))
      bent[64] ^= 1
      expectThrows("hpke \(index) off-curve enc", .invalidPoint) {
        _ = try RestoreImageKey.unwrap(
          fcsResponse: response(Data(bent).base64EncodedString(), wrapped), releaseKey: pem)
      }
      var compressed = [UInt8](data(enc))
      compressed[0] = 0x02
      expectThrows("hpke \(index) non-uncompressed enc", .invalidPoint) {
        _ = try RestoreImageKey.unwrap(
          fcsResponse: response(Data(compressed).base64EncodedString(), wrapped), releaseKey: pem)
      }
    }

    // pyca P-256: a scalar admits its own public point (d*G) and no other.
    let points = v["points"]!
    for (index, item) in points.enumerated() {
      let scalar = [UInt8](data(item["scalar"] as? String))
      let mine = [UInt8](data(item["public"] as? String))
      expect(
        (try? RestoreImageKey.PrivateKey(scalar: scalar, publicKey: mine)) != nil, "point \(index)")
      let theirs = [UInt8](data(points[(index + 1) % points.count]["public"] as? String))
      expectThrows("point \(index), another public key", .invalidPrivateKey) {
        _ = try RestoreImageKey.PrivateKey(scalar: scalar, publicKey: theirs)
      }
    }
    let order = RestoreImageKey.PrivateKey.order
    let generator = RestoreImageKey.PrivateKey.generator
    for (what, scalar) in [
      ("scalar zero", [UInt8](repeating: 0, count: 32)), ("scalar n", order),
      ("scalar n+1", Array(order.dropLast()) + [order[31] + 1]),
      ("scalar 2^256-1", [UInt8](repeating: 0xff, count: 32)), ("short scalar", [1]),
    ] {
      expectThrows(what, .invalidPrivateKey) {
        _ = try RestoreImageKey.PrivateKey(scalar: scalar, publicKey: generator)
      }
    }

    // d = 1 with -G: same x as G, on the curve, so the pair is admitted, and
    // HPKE (which binds the whole point) doesn't open with it. Off the curve
    // with G's x is refused.
    let minusG =
      Array(generator[0..<33])
      + hex("b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a")
    let one = [UInt8](repeating: 0, count: 31) + [1]
    if let pair = try? RestoreImageKey.PrivateKey(scalar: one, publicKey: minusG) {
      let sender = [UInt8](data(hpke[0]["enc"] as? String))
      expectThrows("d = 1 with -G opens nothing", .authentication) {
        _ = try RestoreImageKey.open(
          pair, encapsulated: sender, ciphertext: [UInt8](data(hpke[0]["wrapped"] as? String)),
          info: [])
      }
    } else {
      expect(false, "d = 1 with -G: refused")
    }
    var offCurve = generator
    offCurve[64] ^= 1
    expectThrows("d = 1 with G's x off the curve", .invalidPrivateKey) {
      _ = try RestoreImageKey.PrivateKey(scalar: one, publicKey: offCurve)
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
    // PKCS#8 built here from hpke[0]'s scalar and public key: the canonical
    // shape is admitted; each malformed shape is refused.
    func der(_ tag: UInt8, _ body: [UInt8], long: Int = 0) -> [UInt8] {
      let n = body.count
      var head: [UInt8]
      if n < 0x80 && long == 0 {
        head = [UInt8(n)]
      } else if n < 0x100 && long <= 1 {
        head = [0x81, UInt8(n)]
      } else {
        head = [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
      }
      return [tag] + head + body
    }
    func pkcs8(
      version: [UInt8] = [0], algorithmOID: [UInt8] = RestoreImageKey.DER.ecPublicKey,
      curve: [UInt8] = RestoreImageKey.DER.prime256v1, scalarLong: Int = 0,
      unused: UInt8 = 0, keyTail: [UInt8] = [], tail: [UInt8] = [], outerLong: Int = 0
    ) -> Data {
      let scalar = [UInt8](data(v["hpke"]![0]["scalar"] as? String))
      let point = [UInt8](data(v["hpke"]![0]["public"] as? String))
      let key = der(
        0x30,
        der(0x02, [1]) + der(0x04, scalar, long: scalarLong)
          + der(0xa1, der(0x03, [unused] + point)) + keyTail)
      let info =
        der(
          0x30,
          der(0x02, version) + der(0x30, der(0x06, algorithmOID) + der(0x06, curve))
            + der(0x04, key), long: outerLong) + tail
      return Data(
        "-----BEGIN PRIVATE KEY-----\n\(Data(info).base64EncodedString())\n-----END PRIVATE KEY-----"
          .utf8)
    }
    expect(
      (try? RestoreImageKey.PrivateKey(pem: pkcs8()))?.publicKeyRepresentation
        == data(v["hpke"]![0]["public"] as? String), "DER built here")
    let secp384r1: [UInt8] = [0x2b, 0x81, 0x04, 0x00, 0x22]
    for (what, pem) in [
      ("version 1", pkcs8(version: [1])), ("version 00 00", pkcs8(version: [0, 0])),
      ("not ecPublicKey", pkcs8(algorithmOID: [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x02])),
      ("secp384r1", pkcs8(curve: secp384r1)),
      ("non-minimal length 81 20", pkcs8(scalarLong: 1)),
      ("non-minimal length 82 00 xx", pkcs8(outerLong: 2)),
      ("BIT STRING unused bits", pkcs8(unused: 1)),
      ("byte after the key", pkcs8(tail: [0])),
      ("element after the public key", pkcs8(keyTail: der(0x05, []))),
    ] {
      expectThrows("DER \(what)", .invalidPrivateKey) {
        _ = try RestoreImageKey.PrivateKey(pem: pem)
      }
    }
    expectThrows("DER indefinite length", .invalidPrivateKey) {
      var bytes = [UInt8](
        Data(
          base64Encoded: String(
            String(decoding: pkcs8(), as: UTF8.self)
              .split(separator: "\n")[1]))!)
      bytes[1] = 0x80
      _ = try RestoreImageKey.PrivateKey(
        pem: Data(
          "-----BEGIN PRIVATE KEY-----\n\(Data(bytes).base64EncodedString())\n-----END PRIVATE KEY-----"
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
    // Declared metadata lengths around the bounds, each a single entry that
    // fills the declared length exactly, followed by a salt and root header,
    // so only the length check itself can refuse: zero and 1 MiB + 1 are
    // refused; 1 MiB parses and its root (zeros) fails only to authenticate.
    func sized(_ length: Int) -> Data {
      var out = Data("AEA1".utf8)
      withUnsafeBytes(of: UInt32(1).littleEndian) { out += $0 }
      withUnsafeBytes(of: UInt32(length).littleEndian) { out += $0 }
      if length > 0 {
        withUnsafeBytes(of: UInt32(length).littleEndian) { out += $0 }
        out += Data("k".utf8) + [0] + Data(repeating: 0x76, count: length - 6)
      }
      return out + Data(repeating: 0, count: 32 + 112)
    }
    for (what, length) in [("zero", 0), ("1 MiB + 1", 1024 * 1024 + 1)] {
      expectThrows("metadata length \(what)", .invalidArchive) {
        _ = try RestoreImageKey.metadata(sized(length))
      }
      expectThrows("root, metadata length \(what)", .invalidArchive) {
        try RestoreImageKey.authenticateRoot(
          sized(length), archiveKey: Data(repeating: 42, count: 32))
      }
    }
    expect(
      (try? RestoreImageKey.metadata(sized(1024 * 1024)))?["k"]?.count == 1024 * 1024 - 6,
      "metadata length 1 MiB")
    expectThrows("root, metadata length 1 MiB", .authentication) {
      try RestoreImageKey.authenticateRoot(
        sized(1024 * 1024), archiveKey: Data(repeating: 42, count: 32))
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
    // Metadata, salt, root header MAC, encrypted root header, cluster 0
    // header MAC (each region's first byte) and the last byte.
    let length = Int(head[8]) | Int(head[9]) << 8 | Int(head[10]) << 16 | Int(head[11]) << 24
    for (what, index) in [
      ("metadata", 12), ("salt", 12 + length), ("root MAC", 44 + length),
      ("encrypted root header", 76 + length), ("header MAC", 124 + length),
      ("last", head.count - 1),
    ] {
      var changed = head
      changed[index] ^= 1
      expectThrows("Go AEA root, \(what) byte \(index) changed", .authentication) {
        try RestoreImageKey.authenticateRoot(changed, archiveKey: archiveKey)
      }
    }
    for (index, value) in [(0, UInt8(ascii: "X")), (4, UInt8(2))] {
      var changed = head
      changed[index] = value
      expectThrows("Go AEA root, header byte \(index)", .invalidArchive) {
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
