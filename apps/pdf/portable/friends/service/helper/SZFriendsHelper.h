// Shenzhen Friends helper process: single instance, the local socket, client connections and lifecycle.
//
// The helper is the only process that owns networking, keys, timers and store writes; apps render what it
// publishes (brief § Processes and IPC). It runs from Contents/Helpers/ in each app's bundle, is spawned
// without blocking at launch, and exits a short grace period after its last client disconnects. There is no
// login item. The wire contract with clients is portable/friends/PROTOCOL.md.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - State paths

// Every path the helper owns, derived from one state directory so tests relocate all of it at once. The layout is
// ADR 0003 § Schema v1 (files) and PROTOCOL.md § Transport (socket).
@interface SZFriendsStatePaths : NSObject
// $SZFRIENDS_STATE_DIR when set and absolute, else ~/Library/Application Support/Shenzhen Friends: the rule of
// szfriends_default_state_dir in client/szfriends_client.h, applied to `env` (a unit test keeps the two equal).
+ (NSString *)defaultStateDirectoryWithEnvironment:(NSDictionary<NSString *, NSString *> *)env;
- (instancetype)initWithStateDirectory:(NSString *)stateDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSString *stateDirectory;
@property(nonatomic, readonly) NSString *lockPath;          // helper.lock (flock)
@property(nonatomic, readonly) NSString *socketPath;        // szfriends_socket_path(): ipc/helper.sock or fallback
@property(nonatomic, readonly) NSString *socketDirectory;   // the 0700 directory holding socketPath
@property(nonatomic, readonly) NSString *keysDirectory;     // keys/ (file key store only)
@property(nonatomic, readonly) NSString *picturesDirectory; // pictures/ (own and friends' re-encoded photos)
@property(nonatomic, readonly) NSString *outgoingDirectory; // outgoing/ (immutable snapshots of files being sent)
@property(nonatomic, readonly) NSString *receivedDirectory; // received/ (published files; Show in Finder opens it)
@property(nonatomic, readonly) NSString *partialDirectory;  // received/.partial/ (incoming bytes before the digest)
@property(nonatomic, readonly) NSString *hostListPath;      // hosts.json (newest verified host list)

// Creates the state directory (0700) and the socket directory through szfriends_socket_directory_check(), which
// refuses a socket directory that is a symlink, is owned by another user, or is group/world accessible.
- (BOOL)prepareDirectoriesWithError:(NSError **)error;
@end

#pragma mark - Single instance

// Exclusive, non-blocking flock on helper.lock, taken before binding the socket. A duplicate spawn fails to
// take it and exits at once, so any number of windows and apps may spawn concurrently without a race.
@interface SZFriendsInstanceLock : NSObject
+ (nullable instancetype)acquireAtPath:(NSString *)path error:(NSError **)error; // nil when already held
- (void)releaseLock; // also released by process exit
@end

#pragma mark - Protocol versions (pure)

typedef struct SZFriendsProtocolVersion {
    NSInteger major;
    NSInteger minor;
} SZFriendsProtocolVersion;

// PROTOCOL.md § Version negotiation. The helper speaks its own major and the one before it. Chooses the highest
// major both sides accept, then the lower of the two minors for it. Returns NO when there is none.
BOOL SZFriendsNegotiateProtocol(SZFriendsProtocolVersion helperVersion, NSInteger helperMinMajor,
                                SZFriendsProtocolVersion clientVersion, NSInteger clientMinMajor,
                                SZFriendsProtocolVersion *negotiated);

// Whether a client's embedded helper (from hello.embedded_helper) should replace this running helper:
// compared by protocol major, then minor, then build number.
BOOL SZFriendsEmbeddedHelperIsNewer(SZFriendsProtocolVersion runningProtocol, uint64_t runningBuild,
                                    SZFriendsProtocolVersion embeddedProtocol, uint64_t embeddedBuild);

#pragma mark - Lifecycle policy (pure)

typedef NS_ENUM(NSInteger, SZFriendsExitReason) {
    SZFriendsExitReasonNone = 0,
    SZFriendsExitReasonIdle = 1,     // no clients for the whole grace period
    SZFriendsExitReasonDisabled = 2, // the last client with Friends on sent `disable`: exit without grace
    SZFriendsExitReasonHandover = 3, // a newer embedded helper asked; exit at the next quiet moment
    SZFriendsExitReasonNoClient = 4, // no client ever connected: the app that spawned us died first
};

@interface SZFriendsLifecyclePolicy : NSObject
// Grace after the last client disconnects, so tab detach and multi-window restore (one process per window)
// do not bounce the helper. Default 10 s.
@property(nonatomic) NSTimeInterval gracePeriod;
// Exit this long after start when no client has ever connected. Default 30 s (ADR 0002).
@property(nonatomic) NSTimeInterval firstClientDeadline;
// A handover waits at most this long for an in-flight chunk and an open transaction to settle. Default 5 s
// (ADR 0002); running transfers pause and resume in the successor from the verified byte count.
@property(nonatomic) NSTimeInterval handoverDeadline;

// `lastClientLeft` nil while clients are connected or before the first one came.
- (SZFriendsExitReason)exitReasonWithClientCount:(NSUInteger)clientCount
                                       startedAt:(NSDate *)startedAt
                                  everHadClient:(BOOL)everHadClient
                                  lastClientLeft:(nullable NSDate *)lastClientLeft
                                disabledByLastApp:(BOOL)disabledByLastApp
                              handoverRequestedAt:(nullable NSDate *)handoverRequestedAt
                                     workInFlight:(BOOL)workInFlight
                                             now:(NSDate *)now;
@end

#pragma mark - IPC server

// What the helper learned from a client's hello (PROTOCOL.md § Handshake). Snapshot strings are written for
// this client: its app name, file manager name, capabilities and the formats it opens in place.
@interface SZFriendsClientContext : NSObject
@property(nonatomic, readonly) NSString *appID;
@property(nonatomic, readonly) NSString *appName;
@property(nonatomic, readonly) NSString *appVersion;
@property(nonatomic, readonly) NSString *toolkit;
@property(nonatomic, readonly) NSString *revealIn;
@property(nonatomic, readonly) NSString *locale;
@property(nonatomic, readonly) NSSet<NSString *> *capabilities;
@property(nonatomic, readonly) NSSet<NSString *> *openFormats;
@property(nonatomic, readonly) SZFriendsProtocolVersion negotiatedVersion;
// Parses and validates a hello frame; nil with an error naming the bad field.
+ (nullable instancetype)contextFromHello:(NSDictionary<NSString *, id> *)hello
                        negotiatedVersion:(SZFriendsProtocolVersion)version
                                    error:(NSError **)error;
@end

// One accepted, uid-checked client connection.
@interface SZFriendsIPCConnection : NSObject
@property(nonatomic, readonly) NSString *connectionID;
@property(nonatomic, readonly) pid_t peerPID;
@property(nonatomic, readonly, nullable) SZFriendsClientContext *client; // nil until the hello is accepted
// Serializes one frame as a single line. Frames over the 8 MiB cap are a helper bug: logged, never sent.
- (void)sendFrame:(NSDictionary<NSString *, id> *)frame;
- (void)closeWithGoodbyeReason:(nullable NSString *)reason;
@end

// Receives every intent after a successful handshake. Exactly one reply per intent, sent through `reply`:
// a result dictionary (may be empty), or an error code from PROTOCOL.md § Replies and errors with a display-ready
// message (SZFriendsStrings -messageForErrorCode:details:) and its machine-readable details (`field`, `path`,
// `retry_after_seconds`...; nil sends {}). The server fills `retryable` from the code table.
// Snapshots that reflect the intent's effect must be sent before the reply.
typedef void (^SZFriendsIntentReply)(NSDictionary<NSString *, id> *_Nullable result, NSString *_Nullable errorCode,
                                     NSString *_Nullable message, NSDictionary<NSString *, id> *_Nullable details);

@protocol SZFriendsIntentHandler <NSObject>
- (void)connection:(SZFriendsIPCConnection *)connection
      handleIntent:(NSDictionary<NSString *, id> *)intent
             reply:(SZFriendsIntentReply)reply;
- (void)connectionDidClose:(SZFriendsIPCConnection *)connection;
@end

@interface SZFriendsIPCServer : NSObject
- (instancetype)initWithPaths:(SZFriendsStatePaths *)paths queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, weak, nullable) id<SZFriendsIntentHandler> intentHandler;
// Builds the welcome's helper object, capabilities and strings table for an accepted client.
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> * (^welcomeBuilder)(SZFriendsClientContext *client);
// Called with the embedded helper version from a hello that is newer than this helper.
@property(nonatomic, copy, nullable) void (^onHandoverRequested)(NSDictionary<NSString *, id> *embeddedHelper);

// Binds the socket (removing a stale socket file only while holding helper.lock), listens, and accepts. Each
// connection's peer uid must equal ours (getpeereid); signed builds also check the peer's code signature.
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
@property(nonatomic, readonly) NSArray<SZFriendsIPCConnection *> *connections;
- (void)broadcastGoodbyeWithReason:(NSString *)reason successor:(nullable NSDictionary<NSString *, id> *)successor;
@end

#pragma mark - Entry point

// main() of the helper executable, in this order: in a team-signed build, drop every SZFRIENDS_* variable from its
// environment (SZFriendsEnvironmentOverridesAllowed; logged once), so nothing below can be redirected by another
// process running as the user; take the lock (exit 0 when held, before touching anything else); sodium_init()
// (fatal below 0; libsodium keeps /dev/urandom open from here on); load every bundle resource it will need (word
// list, animal manifest, bootstrap host list), because the updater may replace the bundle while it runs; open
// identity (SZFriendsDefaultKeyStore) and store; bind; start Nearby (only the adapters allowed before the person
// opens Friends) and the host check-in (never under SZFRIENDS_STATE_DIR without a loopback test host list,
// SZFriendsHostCheckIn.h); serve; exit by the lifecycle policy, saying CLOSE on every session. Returns the process
// exit status. The helper bundle has its own identifier, distinct from both apps (ADR 0002), and its Info.plist
// carries the Local Network, Bonjour and Bluetooth usage entries.
int SZFriendsHelperMain(int argc, const char *_Nonnull argv[_Nonnull]);

NS_ASSUME_NONNULL_END
