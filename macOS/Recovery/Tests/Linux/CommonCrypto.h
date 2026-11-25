// Linux test shim: the CommonCrypto calls RestoreImageKey.swift, RestoreImageArchive.swift and
// RecoveryDigest.swift use, plus the ECDH that stands in for Security.framework, all on libcrypto (shim.c).
#include <stddef.h>
#include <stdint.h>
typedef uint32_t CCHmacAlgorithm;
enum { kCCHmacAlgSHA256 = 2 };
#define CC_SHA256_DIGEST_LENGTH 32
typedef uint32_t CC_LONG;
// Room for libcrypto's SHA256_CTX (112 bytes).
typedef struct { uint64_t opaque[16]; } CC_SHA256_CTX;
int CC_SHA256_Init(CC_SHA256_CTX *c);
int CC_SHA256_Update(CC_SHA256_CTX *c, const void *data, CC_LONG len);
int CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *c);
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
// AES-256-CTR (big-endian 128-bit counter) as RestoreImageArchive.swift creates it.
typedef uint32_t CCMode;
typedef uint32_t CCPadding;
typedef uint32_t CCModeOptions;
typedef struct _CCCryptor *CCCryptorRef;
enum { kCCModeCTR = 4, ccNoPadding = 0, kCCModeOptionCTR_BE = 2 };
CCCryptorStatus CCCryptorCreateWithMode(CCOperation op, CCMode mode, CCAlgorithm alg,
                                        CCPadding padding, const void *iv, const void *key,
                                        size_t keyLength, const void *tweak, size_t tweakLength,
                                        int numRounds, CCModeOptions options,
                                        CCCryptorRef *cryptorRef);
CCCryptorStatus CCCryptorUpdate(CCCryptorRef cryptorRef, const void *dataIn, size_t dataInLength,
                                void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved);
CCCryptorStatus CCCryptorRelease(CCCryptorRef cryptorRef);
// x of scalar * peer on P-256. 0 = ok, 1 = scalar not in [1, n-1], 2 = peer not on the curve,
// 3 = libcrypto allocation failed.
int aurora_test_ecdh(const uint8_t *scalar32, const uint8_t *peer65, uint8_t *out32);
