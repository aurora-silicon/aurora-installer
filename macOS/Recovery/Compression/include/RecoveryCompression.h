// LZFSE for the Recovery app, from libcompression (/usr/lib/libcompression.dylib).
// Swift's own Compression module would bring its overlay, libswiftCompression,
// which an older recoveryOS doesn't have (see README), so the two calls the
// restore image needs are declared here and made in C.
#ifndef RECOVERY_COMPRESSION_H
#define RECOVERY_COMPRESSION_H
#include <stddef.h>
#include <stdint.h>

// libcompression's compression_decode_buffer with COMPRESSION_LZFSE: the bytes
// written to dst, at most dst_size; 0 when the input doesn't decode.
size_t aurora_lzfse_decode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size);
// compression_encode_buffer with COMPRESSION_LZFSE; 0 when dst is too small.
size_t aurora_lzfse_encode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size);

#endif
