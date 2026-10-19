/* Shenzhen Friends client library: the signing policy of team-signed apps (ADR 0002 § Peer checks).
 *
 * The helper checks that its clients are signed by its own team and, when it is team-signed, ignores every
 * SZFRIENDS_* variable. This is the app's half of that rule: in a team-signed app the library ignores
 * SZFRIENDS_STATE_DIR and talks only to a helper signed by the same team. Code signatures need Security.framework,
 * which this libc-only library cannot use, so the host passes its team and a verifier; the library decides when to
 * ask and fails closed when it cannot. */

#define _DARWIN_C_SOURCE 1 /* SOL_LOCAL, LOCAL_PEERTOKEN */

#include "client/szfriends_client_internal.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

/* WHY a lock: the reader sets the policy at launch on one queue while its background spawn may already read it on
 * another; the state is a few words and read once per connection attempt, so contention never matters. */
static pthread_mutex_t policy_lock = PTHREAD_MUTEX_INITIALIZER;
static bool policy_signed;
static bool policy_team_valid;
static char policy_requirement[128];
static szfriends_peer_verifier policy_verifier;
static void *policy_context;

/* Apple Team IDs are 10 capitals and digits. Anything else is refused rather than quoted into a requirement, where
 * a quote or a newline could change what the requirement says. */
static bool team_is_valid(const char *team) {
    size_t i;
    if (strlen(team) != 10) return false;
    for (i = 0; i < 10; i++) {
        char c = team[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return false;
    }
    return true;
}

szfriends_status szfriends_set_signing_policy(const char *team_identifier, szfriends_peer_verifier verifier,
                                              void *context) {
    bool is_signed = team_identifier && team_identifier[0];
    bool valid = is_signed && team_is_valid(team_identifier);
    pthread_mutex_lock(&policy_lock);
    policy_signed = is_signed;
    policy_team_valid = valid;
    policy_requirement[0] = '\0';
    /* The helper's own requirement for its clients (SZFriendsPeerRequirementForTeam), so the check is symmetric. */
    if (valid)
        snprintf(policy_requirement, sizeof policy_requirement,
                 "anchor apple generic and certificate leaf[subject.OU] = \"%s\"", team_identifier);
    policy_verifier = is_signed ? verifier : NULL;
    policy_context = is_signed ? context : NULL;
    pthread_mutex_unlock(&policy_lock);
    return is_signed && !valid ? SZFRIENDS_ERR_INVALID_ARGUMENT : SZFRIENDS_OK;
}

bool szfriends_environment_overrides_allowed(void) {
    bool allowed;
    pthread_mutex_lock(&policy_lock);
    /* Fail closed like the identity area's rule: a team string of any shape means someone signed this build. */
    allowed = !policy_signed;
    pthread_mutex_unlock(&policy_lock);
    return allowed;
}

bool szfriends_peer_signature_allowed(int fd) {
    bool is_signed, valid;
    char requirement[sizeof policy_requirement];
    szfriends_peer_verifier verifier;
    void *context;

    pthread_mutex_lock(&policy_lock);
    is_signed = policy_signed;
    valid = policy_team_valid;
    memcpy(requirement, policy_requirement, sizeof requirement);
    verifier = policy_verifier;
    context = policy_context;
    pthread_mutex_unlock(&policy_lock);

    if (!is_signed) return true; /* ad-hoc and test builds: the uid check already ran */
    if (!valid || !verifier) return false;
#if defined(__APPLE__) && defined(LOCAL_PEERTOKEN)
    {
        /* An audit_token_t is eight 32-bit words. Read into a plain array so this file needs no Mach headers; the
         * kernel reports the length it wrote, and anything but a whole token is refused. The token, unlike a pid,
         * cannot be reused by another process after the helper exits. */
        unsigned int token[8];
        socklen_t length = (socklen_t)sizeof token;
        memset(token, 0, sizeof token);
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &length) != 0 || length != (socklen_t)sizeof token)
            return false;
        return verifier(context, token, sizeof token, requirement);
    }
#else
    (void)fd;
    (void)requirement;
    (void)context;
    return false; /* no audit token on this platform, so a signed build cannot prove who listens */
#endif
}
