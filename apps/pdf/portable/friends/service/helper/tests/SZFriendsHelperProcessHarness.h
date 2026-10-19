// Harness for the helper's process tests: spawn real helper processes on temporary state directories, talk to them
// over their socket like an app would, and wait for them with bounded timeouts.
//
// Every helper runs with SZFRIENDS_STATE_DIR set and SZFRIENDS_KEY_STORE=file, so none can reach the Keychain,
// and none is asked to start Nearby or check in, so none touches a radio or the network. Every wait times out
// within 10 s; helpers still alive when the test binary exits are killed.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern int SZFHFailures;
// The state directory of the helper spawned last, whose log a failing test prints.
extern NSString *_Nullable SZFHLastStateDirectory;
// Records a failure with its location and returns NO from the enclosing test.
#define CHECK(cond, ...)                                                                                           \
    do {                                                                                                           \
        if (!(cond)) {                                                                                             \
            SZFHFail(__FILE__, __LINE__, #cond, [NSString stringWithFormat:@"" __VA_ARGS__]);                     \
            return NO;                                                                                             \
        }                                                                                                          \
    } while (0)
void SZFHFail(const char *file, int line, const char *condition, NSString *detail);

@interface SZFHHarness : NSObject
- (instancetype)initWithApp:(NSString *)appPath;
// Tests run against an ad-hoc signed copy, so a bundle signed with a team identity (a release build running the
// suites) does not refuse the unsigned test binary as a client.
- (BOOL)switchToAdHocCopy;
@property(nonatomic, readonly) NSString *appPath;
@property(nonatomic, readonly) NSString *executablePath;

// A fresh directory under the per-user temp dir; removed by -cleanUp.
- (NSString *)makeDirectory;
// posix_spawn of the helper (or `executable`) with only the harness's environment and none of the test's
// descriptors; stderr appends to <state>/helper.log. `timeScale` shortens the lifecycle timings (1 = production).
- (pid_t)spawnHelperWithStateDirectory:(NSString *)stateDirectory timeScale:(double)timeScale;
- (pid_t)spawnExecutable:(NSString *)executable stateDirectory:(NSString *)stateDirectory timeScale:(double)timeScale;
// YES when the process exited within `timeout`; `status` gets its wait status.
- (BOOL)waitForExit:(pid_t)pid timeout:(NSTimeInterval)timeout status:(int *_Nullable)status;
- (BOOL)isRunning:(pid_t)pid;
// Non-blocking: YES when the process has exited (and is reaped, so it is never signalled again).
- (BOOL)reap:(pid_t)pid status:(int *_Nullable)status;
- (NSString *)socketPathForStateDirectory:(NSString *)stateDirectory;
// A copy of the bundle whose Info.plist says build `buildNumber`, re-signed ad hoc; returns its executable.
- (nullable NSString *)copyOfAppWithBuildNumber:(uint64_t)buildNumber;
// The same, at `bundlePath` (inside another app's Contents/Helpers/, say).
- (nullable NSString *)copyOfAppAtPath:(NSString *)bundlePath buildNumber:(uint64_t)buildNumber;
- (NSString *)logForStateDirectory:(NSString *)stateDirectory;
- (void)cleanUp;
@end

@interface SZFHClient : NSObject
// Connects, retrying while nothing listens yet, until `timeout`.
+ (nullable instancetype)connectToSocket:(NSString *)socketPath timeout:(NSTimeInterval)timeout;
- (BOOL)sendLine:(NSString *)line;
- (BOOL)sendData:(NSData *)data timeout:(NSTimeInterval)timeout;
- (BOOL)sendFrame:(NSDictionary *)frame;
// The next frame, or nil at EOF or timeout (`eof` tells which).
- (nullable NSDictionary *)nextFrameWithTimeout:(NSTimeInterval)timeout;
// The next frame of `type`, skipping others (kept in `skipped`).
- (nullable NSDictionary *)nextFrameOfType:(NSString *)type timeout:(NSTimeInterval)timeout;
@property(nonatomic, readonly) BOOL eof;
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *skipped;
// Waits until the helper closes the connection.
- (BOOL)waitForEOFWithTimeout:(NSTimeInterval)timeout;
// Sends the fixture-shaped hello, naming `build` as the embedded helper (0: null), and returns the welcome or the
// first reply.
- (nullable NSDictionary *)helloWithEmbeddedBuild:(uint64_t)build;
// Sends an intent with a fresh id and returns its reply; snapshots that arrive first are collected in `snapshots`.
- (nullable NSDictionary *)intent:(NSString *)type fields:(nullable NSDictionary *)fields;
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *snapshots;
- (void)close;
@end

NS_ASSUME_NONNULL_END
