package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"github.com/go-compressions/lzfse"
	"os"
	"testing"
)

func TestWriteSwiftAEA(t *testing.T) {
	plain := bytes.Repeat([]byte("authenticated AEA segment fixture "), 200)
	compressed, _ := lzfse.Compress(plain)
	key := bytes.Repeat([]byte{42}, 32)
	salt := bytes.Repeat([]byte{7}, 32)
	auth := []byte{10, 0, 0, 0, 't', 'e', 's', 't', 0, 'x'}
	prefix := append([]byte("AEA1"), []byte{1, 0, 0, 0}...)
	prefix = binary.LittleEndian.AppendUint32(prefix, uint32(len(auth)))
	prefix = append(prefix, auth...)
	prefix = append(prefix, salt...)
	main, _ := deriveRange(key, salt, append([]byte("AEA_AMK"), []byte{1, 0, 0, 0}...), 32)
	ck, _ := deriveRange(main, nil, indexedInfo("AEA_CK", 0), 32)
	sm, _ := deriveRange(ck, nil, indexedInfo("AEA_SK", 0), 80)
	encrypted, _ := rangeCTR(sm, compressed)
	mac := func(material, data, salt []byte) []byte {
		h := hmac.New(sha256.New, material[:32])
		h.Write(salt)
		h.Write(data)
		h.Write(binary.LittleEndian.AppendUint64(nil, uint64(len(salt))))
		return h.Sum(nil)
	}
	headerPlain := make([]byte, clusterWidth*40)
	binary.LittleEndian.PutUint32(headerPlain, uint32(len(plain)))
	binary.LittleEndian.PutUint32(headerPlain[4:], uint32(len(encrypted)))
	ph := sha256.Sum256(plain)
	copy(headerPlain[8:], ph[:])
	hm, _ := deriveRange(ck, nil, []byte("AEA_CHEK"), 80)
	hEncrypted, _ := rangeCTR(hm, headerPlain)
	trailer := make([]byte, 32+clusterWidth*32)
	copy(trailer[32:], mac(sm, encrypted, nil))
	header := append(hEncrypted, trailer...)
	headerMAC := mac(hm, hEncrypted, trailer)
	systemSize := len(prefix) + 112 + len(header) + len(encrypted)
	rootPlain := make([]byte, 48)
	binary.LittleEndian.PutUint64(rootPlain, uint64(len(plain)))
	binary.LittleEndian.PutUint64(rootPlain[8:], uint64(systemSize))
	binary.LittleEndian.PutUint32(rootPlain[16:], segmentBytes)
	binary.LittleEndian.PutUint32(rootPlain[20:], clusterWidth)
	rootPlain[24] = 'e'
	rootPlain[25] = 2
	rm, _ := deriveRange(main, nil, []byte("AEA_RHEK"), 80)
	rootEncrypted, _ := rangeCTR(rm, rootPlain)
	rootMAC := mac(rm, rootEncrypted, append(append([]byte{}, headerMAC...), auth...))
	prefix = append(prefix, rootMAC...)
	prefix = append(prefix, rootEncrypted...)
	prefix = append(prefix, headerMAC...)
	rec := func(offset int, data []byte) rangeRecord {
		return rangeRecord{Offset: int64(offset), Size: int64(len(data)), SHA256: digest(data)}
	}
	pr := rec(0, prefix)
	hr := rec(len(prefix), header)
	sr := rec(len(prefix)+len(header), encrypted)
	zip := make([]byte, 31)
	copy(zip, "PK\x03\x04")
	binary.LittleEndian.PutUint16(zip[26:], 1)
	zip[30] = 's'
	recipe := rangeRecipe{Schema: 1, Source: sourceRecord{URL: "https://updates.cdn-apple.com/fixture.ipsw", imageRecord: imageRecord{Size: int64(systemSize + len(zip)), SHA256: digest(zip)}}, System: systemRecord{Member: "s", imageRecord: imageRecord{Size: int64(systemSize), SHA256: digest(append(append(append([]byte{}, prefix...), header...), encrypted...))}, Decoded: imageRecord{Size: int64(len(plain)), SHA256: digest(plain)}}, MemberOffset: int64(len(zip)), ZIPHeader: rec(0, zip), Prefix: pr, Headers: []clusterRecord{{rangeRecord: hr, Cluster: 0, ExpectedMAC: hex.EncodeToString(headerMAC)}}, Segments: map[string]rangeRecord{"0": sr}, Files: []rangeFile{{Source: "source", Name: "test.bin", Transform: "identity", RawSHA256: digest(plain), SHA256: digest(plain), Size: int64(len(plain)), Storage: []storageRecord{{Size: int64(len(plain)), SHA256: digest(plain), Spans: []plainSpan{{Size: int64(len(plain))}}}}}}}
	if err := recipe.validate(); err != nil {
		t.Fatal(err)
	}
	value := map[string]any{"recipe": recipe, "key": base64.StdEncoding.EncodeToString(key), "plain": base64.StdEncoding.EncodeToString(plain), "records": []any{map[string]any{"record": pr, "data": base64.StdEncoding.EncodeToString(prefix)}, map[string]any{"record": hr, "data": base64.StdEncoding.EncodeToString(header)}, map[string]any{"record": sr, "data": base64.StdEncoding.EncodeToString(encrypted)}}}
	out, _ := json.MarshalIndent(value, "", "  ")
	os.WriteFile(os.Getenv("SWIFT_AEA_PATH"), out, 0600)
}
