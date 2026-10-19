/* Link and smoke test for the vendored online transport stack (friends/deps/datachannel.mk).
 *
 * A C99 program, like the helper's C code, that uses libdatachannel only through its C API (rtc.h). It proves the
 * six archives link into a program that needs nothing beyond libc++ and libSystem (check-datachannel.sh inspects
 * the binary), and that the directly compiled stack works end to end: two peer connections in this process open a
 * data channel to each other and echo a message, which runs libjuice's ICE checks, Mbed TLS's DTLS handshake with
 * the DTLS-SRTP extension and certificate fingerprints, and usrsctp's association.
 *
 * Network: both peers bind to 127.0.0.1 and each learns only the other's 127.0.0.1 address, injected as a host
 * candidate; no STUN or TURN server is configured, so nothing leaves the loopback interface. libjuice never
 * gathers loopback addresses itself, which is why the candidates are injected. */

#include <rtc/rtc.h>

#include <mbedtls/version.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define TIMEOUT_SECONDS 20
#define SDP_SIZE 8192

static int failures;

#define EXPECT(condition, ...)                         \
    do {                                               \
        if (!(condition)) {                            \
            fprintf(stderr, "FAIL " __VA_ARGS__);      \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++failures;                                \
        }                                              \
    } while (0)

static const char kGreeting[] = "Shenzhen Friends link test";

typedef struct Peer {
    const char *name;
    int pc;
    unsigned short port;
    struct Peer *other;
} Peer;

/* Written from libdatachannel's threads, read by main: all under the lock. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int echo_received;
static int echo_matches;
static int callback_errors;

static void note_error(const char *what, const char *detail) {
    pthread_mutex_lock(&lock);
    ++callback_errors;
    fprintf(stderr, "FAIL %s: %s\n", what, detail ? detail : "");
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static void RTC_API on_log(rtcLogLevel level, const char *message) {
    if (level <= RTC_LOG_ERROR) fprintf(stderr, "libdatachannel: %s\n", message);
}

/* A free UDP port on 127.0.0.1 for a peer's fixed port range (portRangeBegin = portRangeEnd). */
static unsigned short free_loopback_port(void) {
    struct sockaddr_in addr;
    socklen_t len = sizeof addr;
    unsigned short port = 0;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 0;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) == 0 &&
        getsockname(fd, (struct sockaddr *)&addr, &len) == 0)
        port = ntohs(addr.sin_port);
    close(fd);
    return port;
}

/* The media section's mid, so the injected candidate attaches to the data channel's section. */
static void copy_mid(const char *sdp, char *mid, size_t size) {
    const char *line = strstr(sdp, "a=mid:");
    size_t n = 0;
    mid[0] = '\0';
    if (!line) return;
    line += strlen("a=mid:");
    while (line[n] && line[n] != '\r' && line[n] != '\n' && n + 1 < size) n++;
    memcpy(mid, line, n);
    mid[n] = '\0';
}

/* Signalling stands in for the host: each description goes straight to the other peer, followed by this peer's
 * loopback candidate. Gathered candidates are never forwarded (on_candidate drops them). */
static void RTC_API on_description(int pc, const char *sdp, const char *type, void *ptr) {
    Peer *self = ptr;
    char mid[64], candidate[128];
    (void)pc;
    if (rtcSetRemoteDescription(self->other->pc, sdp, type) < 0) {
        note_error("rtcSetRemoteDescription", self->other->name);
        return;
    }
    copy_mid(sdp, mid, sizeof mid);
    snprintf(candidate, sizeof candidate, "a=candidate:1 1 UDP 2130706431 127.0.0.1 %u typ host",
             (unsigned)self->port);
    if (rtcAddRemoteCandidate(self->other->pc, candidate, mid[0] ? mid : NULL) < 0)
        note_error("rtcAddRemoteCandidate", self->other->name);
}

static void RTC_API on_candidate(int pc, const char *cand, const char *mid, void *ptr) {
    (void)pc;
    (void)cand;
    (void)mid;
    (void)ptr;
}

static void RTC_API on_channel_error(int id, const char *error, void *ptr) {
    (void)id;
    (void)ptr;
    note_error("data channel error", error);
}

/* Answerer: echo every message back on the channel it arrived on. */
static void RTC_API on_answer_message(int id, const char *message, int size, void *ptr) {
    (void)ptr;
    if (rtcSendMessage(id, message, size) < 0) note_error("rtcSendMessage (echo)", NULL);
}

static void RTC_API on_data_channel(int pc, int dc, void *ptr) {
    (void)pc;
    (void)ptr;
    rtcSetErrorCallback(dc, on_channel_error);
    rtcSetMessageCallback(dc, on_answer_message);
}

/* Offerer: send once open, then wait for the echo. A negative size marks a text message. */
static void RTC_API on_offer_open(int id, void *ptr) {
    (void)ptr;
    if (rtcSendMessage(id, kGreeting, -1) < 0) note_error("rtcSendMessage", NULL);
}

static void RTC_API on_offer_message(int id, const char *message, int size, void *ptr) {
    (void)id;
    (void)ptr;
    pthread_mutex_lock(&lock);
    echo_received = 1;
    echo_matches = size < 0 ? strcmp(message, kGreeting) == 0
                            : (size_t)size == strlen(kGreeting) && memcmp(message, kGreeting, (size_t)size) == 0;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static int create_peer(Peer *peer) {
    rtcConfiguration config;
    memset(&config, 0, sizeof config);
    config.bindAddress = "127.0.0.1";
    config.portRangeBegin = peer->port;
    config.portRangeEnd = peer->port;
    peer->pc = rtcCreatePeerConnection(&config);
    if (peer->pc < 0) return -1;
    rtcSetUserPointer(peer->pc, peer);
    rtcSetLocalDescriptionCallback(peer->pc, on_description);
    rtcSetLocalCandidateCallback(peer->pc, on_candidate);
    rtcSetDataChannelCallback(peer->pc, on_data_channel);
    return 0;
}

static void check_versions(void) {
    char version[18];
    /* Header and archive from the same release: a stale build product would mismatch here. */
    mbedtls_version_get_string(version);
    EXPECT(strcmp(version, MBEDTLS_VERSION_STRING) == 0, "Mbed TLS archive %s vs header %s", version,
           MBEDTLS_VERSION_STRING);
    EXPECT(strcmp(MBEDTLS_VERSION_STRING, "3.6.7") == 0, "Mbed TLS is %s, VENDORED.md pins 3.6.7",
           MBEDTLS_VERSION_STRING);
    EXPECT(strcmp(RTC_VERSION, "0.24.6") == 0, "libdatachannel is %s, VENDORED.md pins 0.24.6", RTC_VERSION);
}

/* Waits for the echo or an error, up to TIMEOUT_SECONDS. Returns 1 when the echo arrived. */
static int wait_for_echo(void) {
    struct timeval now;
    struct timespec deadline;
    int done;
    gettimeofday(&now, NULL);
    deadline.tv_sec = now.tv_sec + TIMEOUT_SECONDS;
    deadline.tv_nsec = (long)now.tv_usec * 1000;
    pthread_mutex_lock(&lock);
    while (!echo_received && !callback_errors) {
        if (pthread_cond_timedwait(&changed, &lock, &deadline) != 0) break;
    }
    done = echo_received;
    pthread_mutex_unlock(&lock);
    return done;
}

static void check_selected_pair(int pc) {
    char local[128], remote[128];
    if (rtcGetSelectedCandidatePair(pc, local, sizeof local, remote, sizeof remote) < 0) {
        EXPECT(0, "no selected candidate pair");
        return;
    }
    EXPECT(strstr(local, " 127.0.0.1 ") != NULL, "local candidate is not on loopback: %s", local);
    EXPECT(strstr(remote, " 127.0.0.1 ") != NULL, "remote candidate is not on loopback: %s", remote);
}

static void check_offer(int pc) {
    char *sdp = malloc(SDP_SIZE);
    if (!sdp) {
        EXPECT(0, "out of memory");
        return;
    }
    if (rtcGetLocalDescription(pc, sdp, SDP_SIZE) < 0) {
        EXPECT(0, "no local description");
    } else {
        /* The certificate Mbed TLS generated, and a data-channel-only session. */
        EXPECT(strstr(sdp, "a=fingerprint:sha-256 ") != NULL, "offer has no SHA-256 fingerprint");
        EXPECT(strstr(sdp, "m=application ") != NULL, "offer has no data channel section");
        EXPECT(strstr(sdp, "m=audio") == NULL && strstr(sdp, "m=video") == NULL, "offer has a media section");
    }
    free(sdp);
}

int main(void) {
    Peer offerer = {"offerer", -1, 0, NULL};
    Peer answerer = {"answerer", -1, 0, NULL};
    int dc;

    check_versions();
    rtcInitLogger(RTC_LOG_ERROR, on_log);
    /* The helper's configuration (m2-decision-brief.md): one worker thread for every peer connection. */
    EXPECT(rtcSetThreadPoolSize(1) == RTC_ERR_SUCCESS, "rtcSetThreadPoolSize");

    offerer.other = &answerer;
    answerer.other = &offerer;
    offerer.port = free_loopback_port();
    answerer.port = free_loopback_port();
    while (answerer.port != 0 && answerer.port == offerer.port) answerer.port = free_loopback_port();
    EXPECT(offerer.port != 0 && answerer.port != 0, "no free UDP port on 127.0.0.1");
    EXPECT(create_peer(&offerer) == 0 && create_peer(&answerer) == 0, "rtcCreatePeerConnection");
    if (failures) return 1;

    /* Creating the channel starts negotiation: offer, answer and ICE run from the callbacks above. */
    dc = rtcCreateDataChannel(offerer.pc, "szfriends-link-test");
    EXPECT(dc >= 0, "rtcCreateDataChannel");
    if (dc >= 0) {
        rtcSetErrorCallback(dc, on_channel_error);
        rtcSetOpenCallback(dc, on_offer_open);
        rtcSetMessageCallback(dc, on_offer_message);
        EXPECT(wait_for_echo(), "no echo within %d s", TIMEOUT_SECONDS);
        EXPECT(echo_matches, "echo differs from what was sent");
        check_selected_pair(offerer.pc);
        check_offer(offerer.pc);
        rtcDelete(dc);
    }
    rtcDeletePeerConnection(offerer.pc);
    rtcDeletePeerConnection(answerer.pc);
    rtcCleanup();

    pthread_mutex_lock(&lock);
    failures += callback_errors;
    pthread_mutex_unlock(&lock);
    if (failures) {
        fprintf(stderr, "SZFriendsDataChannelLinkTest failed: %d\n", failures);
        return 1;
    }
    puts("SZFriendsDataChannelLinkTest passed");
    return 0;
}
