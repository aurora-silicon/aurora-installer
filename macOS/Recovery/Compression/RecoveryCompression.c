#include "RecoveryCompression.h"
#include <compression.h>

size_t aurora_lzfse_decode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size) {
  return compression_decode_buffer(dst, dst_size, src, src_size, NULL, COMPRESSION_LZFSE);
}

size_t aurora_lzfse_encode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size) {
  return compression_encode_buffer(dst, dst_size, src, src_size, NULL, COMPRESSION_LZFSE);
}
