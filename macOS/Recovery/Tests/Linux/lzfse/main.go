// LZFSE for the Linux checks, from the pure-Go go-compressions/lzfse (BSD-3-Clause), which its CI
// checks against Apple's libcompression both ways. Built with -buildmode=c-archive it is
// the Recovery app's RecoveryCompression calls (Compression/include/RecoveryCompression.h)
// for Tests/Linux/run.sh; run as a program it compresses stdin to stdout for the fixture
// generators. macOS runs the same checks on libcompression itself (test-all.sh).
package main

// #include <stddef.h>
// #include <stdint.h>
import "C"

import (
	"io"
	"os"
	"unsafe"

	"github.com/go-compressions/lzfse"
)

func put(dst *C.uint8_t, size C.size_t, out []byte) C.size_t {
	n := len(out)
	if n > int(size) {
		n = int(size)
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(size)), out[:n])
	return C.size_t(n)
}

//export aurora_lzfse_decode
func aurora_lzfse_decode(dst *C.uint8_t, dstSize C.size_t, src *C.uint8_t, srcSize C.size_t) C.size_t {
	out, err := lzfse.Decompress(C.GoBytes(unsafe.Pointer(src), C.int(srcSize)))
	if err != nil {
		return 0
	}
	return put(dst, dstSize, out)
}

//export aurora_lzfse_encode
func aurora_lzfse_encode(dst *C.uint8_t, dstSize C.size_t, src *C.uint8_t, srcSize C.size_t) C.size_t {
	out, err := lzfse.Compress(C.GoBytes(unsafe.Pointer(src), C.int(srcSize)))
	if err != nil || len(out) > int(dstSize) {
		return 0
	}
	return put(dst, dstSize, out)
}

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		os.Exit(1)
	}
	out, err := lzfse.Compress(in)
	if err != nil {
		os.Exit(1)
	}
	os.Stdout.Write(out)
}
