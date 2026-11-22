// Linux test shim on libcrypto 3 (declared here: the swift image has no OpenSSL headers).
#include "CommonCrypto.h"
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
