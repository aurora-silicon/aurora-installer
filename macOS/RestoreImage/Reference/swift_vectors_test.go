package main

import (
	"bytes"
	"compress/zlib"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"github.com/go-compressions/lzfse"
	"os"
	"testing"
)

func TestWriteSwiftVectors(t *testing.T) {
	private, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(private)
	ec, _ := private.ECDH()
	pub, _ := hpke.DHKEM(ecdh.P256()).NewPublicKey(ec.PublicKey().Bytes())
	enc, sender, _ := hpke.NewSender(pub, hpke.HKDFSHA256(), hpke.AES256GCM(), nil)
	key := bytes.Repeat([]byte{42}, 32)
	wrapped, _ := sender.Seal(nil, key)
	plain := bytes.Repeat([]byte("synthetic compression fixture "), 200)
	compressed, _ := lzfse.Compress(plain)
	var zb bytes.Buffer
	zw := zlib.NewWriter(&zb)
	zw.Write(plain)
	zw.Close()
	material := bytes.Repeat([]byte{42}, 80)
	ciphertext, _ := rangeCTR(material, plain)
	info := []byte("AEA_RHEK")
	derived, _ := deriveRange(key, []byte("salt"), info, 80)
	mac := hmac.New(sha256.New, material[:32])
	mac.Write([]byte("metadata"))
	mac.Write(ciphertext)
	mac.Write([]byte{8, 0, 0, 0, 0, 0, 0, 0})
	b64 := base64.StdEncoding.EncodeToString
	value := map[string]string{"pem": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "enc": b64(enc), "wrapped": b64(wrapped), "key": b64(key), "plain": b64(plain), "lzfse": b64(compressed), "lzvn": b64(lzfse.CompressLZVN(plain)), "zlib": b64(zb.Bytes()), "material": b64(material), "ciphertext": b64(ciphertext), "hkdf": b64(derived), "mac": hex.EncodeToString(mac.Sum(nil))}
	out, _ := json.MarshalIndent(value, "", "  ")
	os.WriteFile(os.Getenv("SWIFT_VECTOR_PATH"), out, 0600)
}
