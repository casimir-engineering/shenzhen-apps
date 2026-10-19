// The two-helper harness (friends-e2e-check): real helper processes on separate SZFRIENDS_STATE_DIR directories,
// finding each other over loopback Bonjour (and optionally the scripted slow Bluetooth), driven only through the C
// client library the apps use.
//
// Every helper runs with SZFRIENDS_STATE_DIR set and SZFRIENDS_KEY_STORE=file (never the Keychain), a random
// test-only Bonjour type restricted to lo0 (never a Local Network prompt, never a real helper), and no host check-in
// unless a scenario gives it a test host list naming the local Node service on 127.0.0.1 (the host scenario). Every
// wait is bounded; every helper, and the local host service, still running when a scenario or the binary ends is
// killed.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern int SZFE2EFailures;
void SZFE2EFail(const char *file, int line, const char *condition, NSString *detail);
// Records a failure with its location and returns NO from the enclosing scenario.
#define CHECK(cond, ...)                                                                                           \
    do {                                                                                                           \
        if (!(cond)) {                                                                                             \
            SZFE2EFail(__FILE__, __LINE__, #cond, [NSString stringWithFormat:@"" __VA_ARGS__]);                   \
            return NO;                                                                                             \
        }                                                                                                          \
    } while (0)

@interface SZFE2EHelper : NSObject
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *stateDirectory;
@property(nonatomic, readonly) pid_t pid;
// Variables beside the harness's own (SZFRIENDS_E2E_*); applied at the next -start.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *extraEnvironment;
- (BOOL)start;
- (void)kill9;
- (BOOL)terminate; // SIGTERM, then waits for the exit (a helper says goodbye and closes its sessions)
- (BOOL)isRunning;
- (NSString *)log;
@end

@interface SZFE2EClient : NSObject
// Connects through the client library (never spawning: the harness owns the processes) and waits for READY.
+ (nullable instancetype)clientForHelper:(SZFE2EHelper *)helper;
// The same, declaring these capabilities in its hello instead of a plain view's ("drop.files", "attach.items").
+ (nullable instancetype)clientForHelper:(SZFE2EHelper *)helper capabilities:(NSArray<NSString *> *)capabilities;
@property(nonatomic, readonly) BOOL ready;
- (BOOL)waitReady;
// One intent; its reply frame, or nil when none came within 10 s.
- (nullable NSDictionary *)intent:(NSString *)type fields:(nullable NSDictionary *)fields;
// A subscription's id, or nil; its snapshots then keep -dataFor: current.
- (nullable NSString *)subscribe:(NSString *)view params:(nullable NSDictionary *)params;
- (nullable NSString *)openConversation:(NSString *)conversationID;
- (nullable NSDictionary *)dataFor:(NSString *)subscription;
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *goodbyes;
@property(nonatomic, readonly, nullable) NSDictionary *welcome;
- (void)close;
@end

// Processes the harness must kill if the runner exits early (the local host service); -untrack once reaped.
void SZFE2ETrackPID(pid_t pid);
void SZFE2EUntrackPID(pid_t pid);

// Services every open client until `condition` holds or `timeout` passes.
BOOL SZFE2EWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));
void SZFE2EPump(NSTimeInterval seconds);

// One scenario's world: its directory, its Bonjour type, its helpers. -end kills whatever still runs.
@interface SZFE2EWorld : NSObject
- (instancetype)initWithExecutable:(NSString *)executable manifest:(NSString *)manifest root:(NSString *)root;
- (void)beginScenario:(NSString *)name;
- (void)endScenario;
// The end of each of this scenario's helpers' logs, on stderr: what a failing run leaves to read once its directory
// is gone.
- (void)printLogs;
// A helper whose state lives in this scenario's directory; not started.
- (SZFE2EHelper *)helperNamed:(NSString *)name;
// A file of random bytes in the scenario directory.
- (NSString *)fileOfSize:(NSUInteger)size named:(NSString *)name;
// A directory the scripted Bluetooth adapters of this scenario share (short, for sun_path).
@property(nonatomic, readonly) NSString *bluetoothDirectory;
// This scenario's directory and its loopback Bonjour type (a rogue peer browses the same one).
@property(nonatomic, readonly) NSString *scenarioDirectory;
@property(nonatomic, readonly) NSString *serviceType;
@end

NS_ASSUME_NONNULL_END
