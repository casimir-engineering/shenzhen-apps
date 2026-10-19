/*
 * Mbed TLS for the Rust core (build.rs, MBEDTLS_USER_CONFIG_FILE): upstream's default configuration without what
 * neither of its users needs, for ADR 0015 § 12's sizes. The users: libdatachannel's DTLS 1.2 (an ECDSA P-256
 * certificate it makes itself, ECDHE-ECDSA with AES-GCM, as every WebRTC peer and the Mac helper offer) and
 * src/tls.c's TLS 1.2 client for the host connection (ECDHE with RSA or ECDSA certificates, AES-GCM or
 * ChaCha20-Poly1305, chains checked against PEM CA files or by the system). The Mac helper keeps the default
 * configuration; the interop suites run this one against it.
 */

/* Ciphers and modes no suite here uses. */
#undef MBEDTLS_ARIA_C
#undef MBEDTLS_CAMELLIA_C
#undef MBEDTLS_DES_C
#undef MBEDTLS_CCM_C
#undef MBEDTLS_CMAC_C
#undef MBEDTLS_NIST_KW_C
#undef MBEDTLS_CIPHER_MODE_CFB
#undef MBEDTLS_CIPHER_MODE_OFB
#undef MBEDTLS_CIPHER_MODE_XTS
#undef MBEDTLS_CIPHER_PADDING_ONE_AND_ZEROS
#undef MBEDTLS_CIPHER_PADDING_ZEROS_AND_LEN
#undef MBEDTLS_CIPHER_PADDING_ZEROS
#define MBEDTLS_AES_FEWER_TABLES

/* Hashes nothing here signs or checks with. */
#undef MBEDTLS_MD5_C
#undef MBEDTLS_RIPEMD160_C
#undef MBEDTLS_SHA3_C

/* Key exchanges: ECDHE only. */
#undef MBEDTLS_DHM_C
#undef MBEDTLS_KEY_EXCHANGE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_DHE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDHE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_RSA_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_DHE_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDH_ECDSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDH_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECJPAKE_ENABLED
#undef MBEDTLS_ECJPAKE_C

/* Curves: P-256 and P-384 (certificates), P-521 and X25519 (servers' key exchanges). */
#undef MBEDTLS_ECP_DP_SECP192R1_ENABLED
#undef MBEDTLS_ECP_DP_SECP224R1_ENABLED
#undef MBEDTLS_ECP_DP_SECP192K1_ENABLED
#undef MBEDTLS_ECP_DP_SECP224K1_ENABLED
#undef MBEDTLS_ECP_DP_SECP256K1_ENABLED
#undef MBEDTLS_ECP_DP_BP256R1_ENABLED
#undef MBEDTLS_ECP_DP_BP384R1_ENABLED
#undef MBEDTLS_ECP_DP_BP512R1_ENABLED
#undef MBEDTLS_ECP_DP_CURVE448_ENABLED
#undef MBEDTLS_ECP_NIST_OPTIM

/* TLS 1.2 and DTLS 1.2 only, without sessions kept for later. */
#undef MBEDTLS_SSL_PROTO_TLS1_3
#undef MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_EARLY_DATA
#undef MBEDTLS_SSL_SESSION_TICKETS
#undef MBEDTLS_SSL_TICKET_C
#undef MBEDTLS_SSL_CACHE_C
#undef MBEDTLS_SSL_CONTEXT_SERIALIZATION
#undef MBEDTLS_SSL_RECORD_SIZE_LIMIT
#undef MBEDTLS_SSL_ALPN

/* Certificates: parsed and checked, and libdatachannel's own written; no requests or revocation lists. */
#undef MBEDTLS_X509_CSR_PARSE_C
#undef MBEDTLS_X509_CSR_WRITE_C
#undef MBEDTLS_X509_CRL_PARSE_C
#undef MBEDTLS_PKCS12_C
#undef MBEDTLS_PKCS5_C
#undef MBEDTLS_PK_PARSE_EC_EXTENDED
#undef MBEDTLS_PK_PARSE_EC_COMPRESSED
#undef MBEDTLS_PK_RSA_ALT_SUPPORT
#undef MBEDTLS_LMS_C

/* Nothing kept on disk, no self tests, no feature or error text. */
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C
#undef MBEDTLS_PSA_ITS_FILE_C
#undef MBEDTLS_SELF_TEST
#undef MBEDTLS_VERSION_FEATURES
#undef MBEDTLS_ERROR_C
#undef MBEDTLS_PKCS7_C
#undef MBEDTLS_PADLOCK_C
#undef MBEDTLS_AESNI_C
