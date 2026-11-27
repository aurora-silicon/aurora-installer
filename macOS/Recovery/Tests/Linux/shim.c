// Linux test shim on libcrypto 3 (declared here: the swift image has no OpenSSL headers).
#include "CommonCrypto.h"
#include "../../Compression/include/RecoveryCompression.h"
#include <stdlib.h>
#include <string.h>
typedef struct evp_md_st EVP_MD;
typedef struct bignum_st BIGNUM;
typedef struct ec_group_st EC_GROUP;
typedef struct ec_point_st EC_POINT;
const EVP_MD *EVP_sha256(void);
unsigned char *HMAC(const EVP_MD *, const void *, int, const unsigned char *, size_t,
                    unsigned char *, unsigned int *);
int AES_set_encrypt_key(const unsigned char *, int, void *);
void AES_encrypt(const unsigned char *, unsigned char *, const void *);
EC_GROUP *EC_GROUP_new_by_curve_name(int);
void EC_GROUP_free(EC_GROUP *);
const BIGNUM *EC_GROUP_get0_order(const EC_GROUP *);
EC_POINT *EC_POINT_new(const EC_GROUP *);
void EC_POINT_free(EC_POINT *);
int EC_POINT_oct2point(const EC_GROUP *, EC_POINT *, const unsigned char *, size_t, void *);
int EC_POINT_mul(const EC_GROUP *, EC_POINT *, const BIGNUM *, const EC_POINT *, const BIGNUM *,
                 void *);
int EC_POINT_is_at_infinity(const EC_GROUP *, const EC_POINT *);
int EC_POINT_get_affine_coordinates(const EC_GROUP *, const EC_POINT *, BIGNUM *, BIGNUM *, void *);
BIGNUM *BN_bin2bn(const unsigned char *, int, BIGNUM *);
BIGNUM *BN_new(void);
void BN_free(BIGNUM *);
int BN_cmp(const BIGNUM *, const BIGNUM *);
int BN_is_zero(const BIGNUM *);
int BN_bn2binpad(const BIGNUM *, unsigned char *, int);
int SHA256_Init(void *);
int SHA256_Update(void *, const void *, size_t);
int SHA256_Final(unsigned char *, void *);

int CC_SHA256_Init(CC_SHA256_CTX *c) { return SHA256_Init(c); }
int CC_SHA256_Update(CC_SHA256_CTX *c, const void *d, CC_LONG n) { return SHA256_Update(c, d, n); }
int CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *c) { return SHA256_Final(md, c); }

void CCHmac(CCHmacAlgorithm alg, const void *key, size_t kl, const void *d, size_t dl, void *out) {
  unsigned int n = 0;
  static const unsigned char z = 0;
  if (alg != kCCHmacAlgSHA256) {
    memset(out, 0, 32);
    return;
  }
  HMAC(EVP_sha256(), kl ? key : &z, (int)kl, dl ? d : &z, dl, out, &n);
}

CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions o, const void *key, size_t kl,
                        const void *iv, const void *in, size_t n, void *out, size_t avail,
                        size_t *moved) {
  unsigned char ks[512];
  (void)iv;
  if (op != kCCEncrypt || alg != kCCAlgorithmAES || o != kCCOptionECBMode || n % 16 || avail < n)
    return -4300;
  if (AES_set_encrypt_key(key, (int)kl * 8, ks) != 0) return -4301;
  for (size_t i = 0; i < n; i += 16)
    AES_encrypt((const unsigned char *)in + i, (unsigned char *)out + i, ks);
  *moved = n;
  return kCCSuccess;
}

struct _CCCryptor {
  unsigned char ks[512];
  unsigned char counter[16];
  unsigned char stream[16];
  size_t used;
};

CCCryptorStatus CCCryptorCreateWithMode(CCOperation op, CCMode mode, CCAlgorithm alg,
                                        CCPadding padding, const void *iv, const void *key,
                                        size_t kl, const void *tweak, size_t tl, int rounds,
                                        CCModeOptions options, CCCryptorRef *out) {
  (void)tweak;
  struct _CCCryptor *c;
  if (op != kCCEncrypt || mode != kCCModeCTR || alg != kCCAlgorithmAES || padding != ccNoPadding ||
      !iv || kl != 32 || tl || rounds || options != kCCModeOptionCTR_BE || !out)
    return -4300;
  c = calloc(1, sizeof *c);
  if (!c) return -4302;
  if (AES_set_encrypt_key(key, 256, c->ks) != 0) {
    free(c);
    return -4301;
  }
  memcpy(c->counter, iv, 16);
  c->used = 16;
  *out = c;
  return kCCSuccess;
}

CCCryptorStatus CCCryptorUpdate(CCCryptorRef c, const void *in, size_t n, void *out, size_t avail,
                                size_t *moved) {
  if (avail < n) return -4300;
  for (size_t i = 0; i < n; i++) {
    if (c->used == 16) {
      AES_encrypt(c->counter, c->stream, c->ks);
      for (int b = 15; b >= 0 && ++c->counter[b] == 0; b--) {
      }
      c->used = 0;
    }
    ((unsigned char *)out)[i] = ((const unsigned char *)in)[i] ^ c->stream[c->used++];
  }
  *moved = n;
  return kCCSuccess;
}

CCCryptorStatus CCCryptorRelease(CCCryptorRef c) {
  free(c);
  return kCCSuccess;
}

#ifndef AURORA_LZFSE_GO
// LZFSE stand-in when run.sh couldn't build lzfse/ (the Go decoder): Linux has no
// libcompression, and the swift image no liblzfse. Only
// uncompressed blocks ("bvx-") and the end-of-stream block ("bvx$") are decoded, and
// encoding writes them; both are valid LZFSE, which macOS's own decoder reads (test-all.sh
// runs the same checks there on real LZFSE). Any other block decodes as an error (0).
static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

size_t aurora_lzfse_decode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size) {
  size_t in = 0, out = 0;
  while (src_size - in >= 4) {
    if (!memcmp(src + in, "bvx$", 4)) return out;
    if (memcmp(src + in, "bvx-", 4) || src_size - in < 8) return 0;
    size_t n = le32(src + in + 4);
    if (src_size - in - 8 < n) return 0;
    size_t take = n < dst_size - out ? n : dst_size - out;
    memcpy(dst + out, src + in + 8, take);
    out += take;
    if (take < n) return out;  // dst full: libcompression stops there too
    in += 8 + n;
  }
  return 0;
}

size_t aurora_lzfse_encode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size) {
  if (dst_size < src_size + 12) return 0;
  memcpy(dst, "bvx-", 4);
  for (int i = 0; i < 4; i++) dst[4 + i] = (uint8_t)(src_size >> (8 * i));
  memcpy(dst + 8, src, src_size);
  memcpy(dst + 8 + src_size, "bvx$", 4);
  return src_size + 12;
}
#endif

int aurora_test_ecdh(const uint8_t *scalar32, const uint8_t *peer65, uint8_t *out32) {
  int status = 2;
  EC_GROUP *group = EC_GROUP_new_by_curve_name(415 /* NID_X9_62_prime256v1 */);
  EC_POINT *peer = EC_POINT_new(group), *shared = EC_POINT_new(group);
  BIGNUM *d = BN_bin2bn(scalar32, 32, NULL), *x = BN_new();
  if (!group || !peer || !shared || !d || !x)
    status = 3;
  else if (BN_is_zero(d) || BN_cmp(d, EC_GROUP_get0_order(group)) >= 0)
    status = 1;
  else if (EC_POINT_oct2point(group, peer, peer65, 65, NULL) == 1 &&
           EC_POINT_mul(group, shared, NULL, peer, d, NULL) == 1 &&
           !EC_POINT_is_at_infinity(group, shared) &&
           EC_POINT_get_affine_coordinates(group, shared, x, NULL, NULL) == 1 &&
           BN_bn2binpad(x, out32, 32) == 32)
    status = 0;
  BN_free(x);
  BN_free(d);
  EC_POINT_free(shared);
  EC_POINT_free(peer);
  EC_GROUP_free(group);
  return status;
}
