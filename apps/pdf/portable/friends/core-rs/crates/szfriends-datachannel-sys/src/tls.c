// A TLS 1.2 client on the Mbed TLS the data-channel stack already carries, for the host connection's wss:// (src/tls.rs
// is its Rust side). TLS 1.2 only: its handshake uses Mbed TLS's own crypto objects, never the PSA key store that
// TLS 1.3 shares process-wide with the stack's DTLS threads (built without MBEDTLS_THREADING_C).
//
// Who the server is: with roots given (tests: their own CA; Linux and Android: the system's CA files), Mbed TLS checks
// the chain and the name itself. Without them (Windows, Apple systems), the handshake keeps the server's chain and
// szf_tls_platform_verify asks the system, as a browser there would: CertGetCertificateChain and the SSL policy on
// Windows, SecTrust on Apple systems.

#include <stdlib.h>
#include <string.h>

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#if defined(_WIN32)
#include <windows.h>
#include <wincrypt.h>
#elif defined(__APPLE__)
#include <Security/Security.h>
#endif

typedef int (*szf_tls_send_fn)(void *io, const unsigned char *buf, size_t len);
typedef int (*szf_tls_recv_fn)(void *io, unsigned char *buf, size_t len);

typedef struct szf_tls {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt roots;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    int roots_count;
} szf_tls;

szf_tls *szf_tls_new(void) {
    szf_tls *tls = calloc(1, sizeof(szf_tls));
    if (tls == NULL) return NULL;
    mbedtls_ssl_init(&tls->ssl);
    mbedtls_ssl_config_init(&tls->conf);
    mbedtls_x509_crt_init(&tls->roots);
    mbedtls_entropy_init(&tls->entropy);
    mbedtls_ctr_drbg_init(&tls->drbg);
    static const unsigned char personal[] = "szfriends-host-tls";
    if (mbedtls_ctr_drbg_seed(&tls->drbg, mbedtls_entropy_func, &tls->entropy, personal, sizeof personal - 1) != 0) {
        mbedtls_ctr_drbg_free(&tls->drbg);
        mbedtls_entropy_free(&tls->entropy);
        free(tls);
        return NULL;
    }
    return tls;
}

void szf_tls_free(szf_tls *tls) {
    if (tls == NULL) return;
    mbedtls_ssl_free(&tls->ssl);
    mbedtls_ssl_config_free(&tls->conf);
    mbedtls_x509_crt_free(&tls->roots);
    mbedtls_ctr_drbg_free(&tls->drbg);
    mbedtls_entropy_free(&tls->entropy);
    free(tls);
}

// PEM (NUL-terminated, several certificates) or one DER certificate; the number now held. Bad entries are skipped.
int szf_tls_add_roots(szf_tls *tls, const unsigned char *data, size_t len) {
    (void)mbedtls_x509_crt_parse(&tls->roots, data, len);
    int count = 0;
    for (const mbedtls_x509_crt *crt = &tls->roots; crt != NULL && crt->raw.len > 0; crt = crt->next) count++;
    tls->roots_count = count;
    return count;
}

// hostname: checked against the certificate and sent as SNI. With roots added, Mbed TLS checks the chain; without,
// the caller must call szf_tls_platform_verify after the handshake.
int szf_tls_setup(szf_tls *tls, const char *hostname, void *io, szf_tls_send_fn send, szf_tls_recv_fn recv) {
    int ret = mbedtls_ssl_config_defaults(&tls->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                          MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return ret;
    mbedtls_ssl_conf_min_tls_version(&tls->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&tls->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_rng(&tls->conf, mbedtls_ctr_drbg_random, &tls->drbg);
    if (tls->roots_count > 0) {
        mbedtls_ssl_conf_ca_chain(&tls->conf, &tls->roots, NULL);
        mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    } else {
        // The system decides after the handshake (szf_tls_platform_verify); nothing is sent before it has.
        mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
    }
    if ((ret = mbedtls_ssl_setup(&tls->ssl, &tls->conf)) != 0) return ret;
    if ((ret = mbedtls_ssl_set_hostname(&tls->ssl, hostname)) != 0) return ret;
    mbedtls_ssl_set_bio(&tls->ssl, io, (mbedtls_ssl_send_t *)send, (mbedtls_ssl_recv_t *)recv, NULL);
    return 0;
}

int szf_tls_handshake(szf_tls *tls) {
    return mbedtls_ssl_handshake(&tls->ssl);
}

int szf_tls_read(szf_tls *tls, unsigned char *buf, size_t len) {
    return mbedtls_ssl_read(&tls->ssl, buf, len);
}

int szf_tls_write(szf_tls *tls, const unsigned char *buf, size_t len) {
    return mbedtls_ssl_write(&tls->ssl, buf, len);
}

void szf_tls_close_notify(szf_tls *tls) {
    (void)mbedtls_ssl_close_notify(&tls->ssl);
}

#if defined(_WIN32)
static int platform_verify(const mbedtls_x509_crt *peer, const char *hostname) {
    int ok = 0;
    HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
    PCCERT_CONTEXT leaf = NULL;
    PCCERT_CHAIN_CONTEXT chain = NULL;
    wchar_t name[256];
    if (store == NULL || MultiByteToWideChar(CP_UTF8, 0, hostname, -1, name, 256) == 0) goto done;
    for (const mbedtls_x509_crt *crt = peer; crt != NULL && crt->raw.len > 0; crt = crt->next) {
        if (!CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING, crt->raw.p, (DWORD)crt->raw.len,
                                              CERT_STORE_ADD_ALWAYS, crt == peer ? &leaf : NULL)) {
            goto done;
        }
    }
    LPSTR usage = szOID_PKIX_KP_SERVER_AUTH;
    CERT_CHAIN_PARA para;
    memset(&para, 0, sizeof para);
    para.cbSize = sizeof para;
    para.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
    para.RequestedUsage.Usage.cUsageIdentifier = 1;
    para.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    if (leaf == NULL || !CertGetCertificateChain(NULL, leaf, NULL, store, &para, 0, NULL, &chain)) goto done;
    SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl;
    memset(&ssl, 0, sizeof ssl);
    ssl.cbSize = sizeof ssl;
    ssl.dwAuthType = AUTHTYPE_SERVER;
    ssl.pwszServerName = name;
    CERT_CHAIN_POLICY_PARA policy;
    memset(&policy, 0, sizeof policy);
    policy.cbSize = sizeof policy;
    policy.pvExtraPolicyPara = &ssl;
    CERT_CHAIN_POLICY_STATUS status;
    memset(&status, 0, sizeof status);
    status.cbSize = sizeof status;
    ok = CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &status) && status.dwError == 0;
done:
    if (chain != NULL) CertFreeCertificateChain(chain);
    if (leaf != NULL) CertFreeCertificateContext(leaf);
    if (store != NULL) CertCloseStore(store, 0);
    return ok;
}
#elif defined(__APPLE__)
static int platform_verify(const mbedtls_x509_crt *peer, const char *hostname) {
    int ok = 0;
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFStringRef name = CFStringCreateWithCString(NULL, hostname, kCFStringEncodingUTF8);
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    if (certificates == NULL || name == NULL) goto done;
    for (const mbedtls_x509_crt *crt = peer; crt != NULL && crt->raw.len > 0; crt = crt->next) {
        CFDataRef data = CFDataCreate(NULL, crt->raw.p, (CFIndex)crt->raw.len);
        SecCertificateRef certificate = data != NULL ? SecCertificateCreateWithData(NULL, data) : NULL;
        if (data != NULL) CFRelease(data);
        if (certificate == NULL) goto done;
        CFArrayAppendValue(certificates, certificate);
        CFRelease(certificate);
    }
    policy = SecPolicyCreateSSL(true, name);
    if (policy == NULL || SecTrustCreateWithCertificates(certificates, policy, &trust) != errSecSuccess) goto done;
    ok = SecTrustEvaluateWithError(trust, NULL) ? 1 : 0;
done:
    if (trust != NULL) CFRelease(trust);
    if (policy != NULL) CFRelease(policy);
    if (name != NULL) CFRelease(name);
    if (certificates != NULL) CFRelease(certificates);
    return ok;
}
#else
static int platform_verify(const mbedtls_x509_crt *peer, const char *hostname) {
    (void)peer;
    (void)hostname;
    return 0;
}
#endif

// After the handshake: 1 when the server is who `hostname` names. With roots added, Mbed TLS's own check (which the
// handshake already required); without, the system's.
int szf_tls_verified(szf_tls *tls, const char *hostname) {
    if (tls->roots_count > 0) return mbedtls_ssl_get_verify_result(&tls->ssl) == 0;
    const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&tls->ssl);
    return peer != NULL && platform_verify(peer, hostname);
}
