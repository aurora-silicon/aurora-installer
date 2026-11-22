// Linux test shim: the CommonCrypto calls RestoreImageKey.swift uses, plus the
// ECDH that stands in for Security.framework, all on libcrypto (shim.c).
#include <stddef.h>
#include <stdint.h>
typedef uint32_t CCHmacAlgorithm;
enum { kCCHmacAlgSHA256 = 2 };
#define CC_SHA256_DIGEST_LENGTH 32
void CCHmac(CCHmacAlgorithm alg, const void *key, size_t keyLength, const void *data,
            size_t dataLength, void *macOut);
typedef uint32_t CCOperation;
typedef uint32_t CCAlgorithm;
typedef uint32_t CCOptions;
typedef int32_t CCCryptorStatus;
enum { kCCEncrypt = 0, kCCAlgorithmAES = 0, kCCOptionECBMode = 2, kCCSuccess = 0 };
CCCryptorStatus CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options, const void *key,
                        size_t keyLength, const void *iv, const void *dataIn, size_t dataInLength,
                        void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved);
// x of scalar * peer on P-256. 0 = ok, 1 = scalar not in [1, n-1], 2 = peer not on the curve,
// 3 = libcrypto allocation failed.
int aurora_test_ecdh(const uint8_t *scalar32, const uint8_t *peer65, uint8_t *out32);
