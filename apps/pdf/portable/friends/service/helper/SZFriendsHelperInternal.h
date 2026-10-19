// Shenzhen Friends helper internals: declarations shared by the helper's own files, not by other areas.
//
// The public contract is SZFriendsHelper.h; this header holds the seams the helper's tests drive (peer checks
// with injected credentials, JSON type checks, the lifecycle controller) and the hooks between the IPC server,
// the lifecycle and the dispatch layer.

#import <Foundation/Foundation.h>
#import <bsm/audit.h>
#import <sys/types.h>

#import "service/helper/SZFriendsHelper.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

// One line to stderr, which the spawner points at the helper log. Never pass secrets, message text or file
// names: the log is for lifecycle and protocol faults only.
void SZFriendsHelperLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - Build identity

// The running helper's version, read from its bundle's Info.plist (CFBundleShortVersionString, then the app build in
// the last two digits of SZFriendsBuildNumber, which CFBundleVersion repeats for the views), so a test can make
// build N+1 by editing a copy's Info.plist and re-signing it. Zero and "0" when the executable runs outside a bundle.
NSString *SZFriendsHelperVersionString(void);
uint64_t SZFriendsHelperBuildNumber(void);
SZFriendsProtocolVersion SZFriendsHelperProtocolVersion(void);

// Multiplies the lifecycle timings (10 s grace, 30 s first client, 5 s handover) so process tests finish within
// their 10 s budget. Honoured only when SZFRIENDS_STATE_DIR is set, which production never does, and clamped to
// [0.01, 1] so it can only shorten them. Variable: SZFRIENDS_HELPER_TIME_SCALE.
double SZFriendsHelperTimeScale(NSDictionary<NSString *, NSString *> *env);

// The environment a helper may act on. Where overrides are not allowed (a team-signed build, which the identity
// area's SZFriendsEnvironmentOverridesAllowed decides) every SZFRIENDS_* variable is dropped: the state directory,
// the key store and the test variables. WHY: another process running as the user could set them with launchctl
// setenv and move the helper to a plaintext key store and a state directory of its choosing (review: environment
// overrides). Unsigned and ad-hoc builds, which the tests run, keep them. `ignored` receives the names dropped.
NSDictionary<NSString *, NSString *> *SZFriendsHelperTrustedEnvironment(
    NSDictionary<NSString *, NSString *> *env, BOOL overridesAllowed,
    NSArray<NSString *> *_Nullable *_Nullable ignored);

#pragma mark - JSON field checks

// NSJSONSerialization turns true/false into NSNumber too, so "is a number" is not "is an integer".
BOOL SZFriendsJSONIsInteger(id _Nullable value);
BOOL SZFriendsJSONIsBool(id _Nullable value);
BOOL SZFriendsJSONIsString(id _Nullable value);
// A frame id: 1 to 32 printable ASCII characters (PROTOCOL.md § Framing).
BOOL SZFriendsFrameIDIsValid(id _Nullable value);
// "2026-10-12T06:51:10Z".
NSString *SZFriendsRFC3339(NSDate *date);

#pragma mark - Peer checks

// What the kernel says about the process at the other end of an accepted socket.
typedef struct SZFriendsPeerCredentials {
    BOOL hasUID;
    uid_t uid;
    pid_t pid;
    BOOL hasAuditToken;
    audit_token_t auditToken; // LOCAL_PEERTOKEN: unlike a pid, it cannot be reused by another process
} SZFriendsPeerCredentials;

BOOL SZFriendsReadPeerCredentials(int fd, SZFriendsPeerCredentials *credentials);

// The uid rule alone (PROTOCOL.md § Peer checks): another user's process never talks to this helper.
BOOL SZFriendsPeerUIDAllowed(const SZFriendsPeerCredentials *credentials, uid_t ownUID);

// A team identifier as Apple issues them (10 upper-case letters and digits). Anything else is refused before it
// can reach a requirement string.
BOOL SZFriendsTeamIdentifierIsValid(NSString *_Nullable team);
// anchor apple generic and certificate leaf[subject.OU] = "<team>" (ADR 0002 § Peer checks).
NSString *SZFriendsPeerRequirementForTeam(NSString *team);
// The helper's own team from its signature; nil for ad-hoc and unsigned builds, which check the uid only.
NSString *_Nullable SZFriendsOwnTeamIdentifier(void);

typedef BOOL (^SZFriendsRequirementChecker)(audit_token_t token, NSString *requirement);
// The production checker: the peer's code from its audit token (kSecGuestAttributeAudit), validated against the
// requirement.
SZFriendsRequirementChecker SZFriendsSecurityRequirementChecker(void);

// The whole decision: uid first; then, only in builds signed with a team, an audit token whose code satisfies
// the team requirement. A team-signed helper refuses a peer without a token rather than skipping the check.
BOOL SZFriendsPeerAllowed(const SZFriendsPeerCredentials *credentials, uid_t ownUID, NSString *_Nullable team,
                          SZFriendsRequirementChecker _Nullable checker);

#pragma mark - Handover claims

// Whether a claimed successor build is one this helper could plausibly be replaced by: no more than one year of
// builds ahead of its own. Build numbers are YYMMDDBB (helper.mk), so a year ahead is YY + 1 on the same day.
// WHY: any connected client names a build in its hello, and an absurd one (2^53 - 1) would make every helper step
// aside for a successor that never comes (review: handover denial of service).
BOOL SZFriendsHandoverBuildIsPlausible(uint64_t runningBuild, uint64_t claimedBuild);
// The executable of the process at the other end of a socket, from its audit token (which, unlike a pid, cannot
// name another process later); nil when the kernel cannot say.
NSString *_Nullable SZFriendsPeerExecutablePath(const SZFriendsPeerCredentials *credentials);
// The build numbers the app whose main executable is `executablePath` embeds as its Friends helper
// (<App>.app/Contents/Helpers/Shenzhen Friends.app: SZFriendsBuildNumber and CFBundleVersion). Empty when the
// executable is not an app's main executable, or the app embeds no readable helper. The Info.plist is read only when
// it is a small regular file, so a client cannot stall the helper with a pipe or a huge file in its place.
NSSet<NSNumber *> *SZFriendsEmbeddedHelperBuildsOfApp(NSString *_Nullable executablePath);

#pragma mark - State directory

@interface SZFriendsStatePaths ()
// The state directory alone, 0700, before the lock can be taken; -prepareDirectoriesWithError: adds the socket
// directory once the lock is held.
- (BOOL)prepareStateDirectoryWithError:(NSError **)error;
@end

#pragma mark - IPC server hooks

@interface SZFriendsIPCConnection ()
// Set when the client sent `disable`: it no longer keeps the helper alive (PROTOCOL.md § Lifecycle).
@property(nonatomic) BOOL sentDisable;
// What the kernel said about the client at accept: who may ask for a handover (SZFriendsEmbeddedHelperBuildsOfApp).
@property(nonatomic) SZFriendsPeerCredentials peerCredentials;
// Opaque per-connection state owned by the dispatch layer (subscriptions, the strings for this audience).
@property(nonatomic, strong, nullable) id dispatchState;
@end

@interface SZFriendsIPCServer ()
// Accepted, uid-checked connections came or went; the lifecycle re-evaluates. `closedConnection` is nil on accept.
@property(nonatomic, copy, nullable) void (^onConnectionsChanged)(SZFriendsIPCConnection *_Nullable closedConnection);
// Overrides for tests of the peer decision; production uses getpeereid and the Security checker.
@property(nonatomic, copy, nullable) NSString *teamIdentifier;
// Stops accepting new clients (handover) while existing connections keep their sessions until the goodbye.
- (void)stopAccepting;
@end

#pragma mark - Lifecycle controller

// Applies SZFriendsLifecyclePolicy to the live server: re-evaluates on every connection change and on timers,
// and calls `onExit` once with the reason. Runs on the helper queue.
@interface SZFriendsHelperLifecycle : NSObject
- (instancetype)initWithPolicy:(SZFriendsLifecyclePolicy *)policy
                        server:(SZFriendsIPCServer *)server
                         queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, copy, nullable) void (^onExit)(SZFriendsExitReason reason);
// Whether a chunk is in flight or a store transaction is open; handover waits for NO (at most the deadline).
@property(nonatomic, copy, nullable) BOOL (^workInFlight)(void);
- (void)start;
- (void)connectionsChanged:(nullable SZFriendsIPCConnection *)closedConnection;
- (void)connectionSentDisable:(SZFriendsIPCConnection *)connection;
// A newer embedded helper asked to take over; the newest successor named so far is announced in the goodbye.
- (void)requestHandoverWithSuccessor:(NSDictionary<NSString *, id> *)embeddedHelper;
- (void)shutdownForSignal:(int)signalNumber;
@end

NS_ASSUME_NONNULL_END
