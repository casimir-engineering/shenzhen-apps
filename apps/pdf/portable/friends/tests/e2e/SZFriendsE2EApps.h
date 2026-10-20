// friends-e2e-check: apps as processes of their own, for the scenarios where it matters which app talks to the helper
// (two apps sharing one helper, and handover between them).
//
// An app is a test bundle <Name>.app whose Contents/MacOS/<Name> is one of the two app programs
// (szfriends_e2e_client_app.c plays ShenzhenPDF through the C client library, szfriends_e2e_gtk_app.c plays Shenzhen
// Files through the GTK views' link, display-free) and whose Contents/Helpers/Shenzhen Friends.app wraps the e2e
// helper with an Info.plist naming its build. A helper believes a handover request only from an app that carries the
// build it names (SZFriendsEmbeddedHelperBuildsOfApp), so the bundle is what makes the request genuine. The app's
// client library spawns that embedded helper when nothing answers, with the app's environment, so the harness's test
// variables (state directory, file key store, loopback Bonjour type) reach it as they reach the harness's helpers.
//
// The runner talks to each app over its stdin and stdout, one JSON object per line; every wait is bounded.

#import "SZFriendsE2EHarness.h"

NS_ASSUME_NONNULL_BEGIN

// Builds <directory>/<name>.app around `program`, embedding a helper bundle around `helper` that says `build`.
// Returns the app's executable, or nil.
NSString *_Nullable SZFE2EMakeAppBundle(NSString *directory, NSString *name, NSString *program, NSString *helper,
                                        uint64_t build);
// The embedded helper's executable inside an app built above.
NSString *SZFE2EAppHelperExecutable(NSString *appExecutable);
// Changes the build the app's embedded helper says (an update of the app that carries a newer helper).
BOOL SZFE2ESetAppHelperBuild(NSString *appExecutable, uint64_t build);
// The executable of a running process, or nil.
NSString *_Nullable SZFE2EProcessPath(pid_t pid);

@interface SZFE2EApp : NSObject
// Starts the app with `environment` as its whole environment. Its stderr goes to <executable>.log.
+ (nullable instancetype)launch:(NSString *)executable build:(uint64_t)build
                    environment:(NSDictionary<NSString *, NSString *> *)environment;
// The same, for an app whose program lives outside its bundle (a driver that runs the app it names): `helper` is
// the embedded helper the program is told about.
+ (nullable instancetype)launch:(NSString *)executable helper:(NSString *)helper build:(uint64_t)build
                    environment:(NSDictionary<NSString *, NSString *> *)environment;
@property(nonatomic, readonly) NSString *executable;
@property(nonatomic, readonly) pid_t pid;
// The last connection state the app reported ("ready", "waiting", ...) and, while ready, its helper's pid.
@property(nonatomic, readonly, copy) NSString *state;
@property(nonatomic, readonly) pid_t helperPID;
// Every helper pid this app was ready on, in order.
@property(nonatomic, readonly) NSArray<NSNumber *> *helperPIDs;
@property(nonatomic, readonly, nullable) NSDictionary *list;
@property(nonatomic, readonly) NSArray<NSDictionary *> *goodbyes; // goodbye frames (the C client app reports them)
@property(nonatomic, readonly) NSArray<NSDictionary *> *welcomes; // welcome frames (the C client app reports them)
- (nullable NSDictionary *)conversation:(NSString *)conversationID;
// The last snapshot of any other view the app reported ("profile"), by the name it gave.
- (nullable NSDictionary *)view:(NSString *)name;
- (nullable NSDictionary *)replyTagged:(NSString *)tag;
- (void)send:(NSDictionary *)command;
// Reads whatever the app wrote since the last call. Wait conditions call it, so the harness's pump serves both.
- (void)drain;
// Waits until the app is ready on a helper; that helper's pid, or 0.
- (pid_t)waitReady:(NSTimeInterval)timeout;
// Asks the app to quit and waits for it, killing it after `timeout`; YES when it quit by itself.
- (BOOL)quitWithin:(NSTimeInterval)timeout;
- (NSString *)log;
@end

// Kills each helper pid that still runs an executable under `directory` (never a pid reused by anything else), then
// waits for them to be gone.
void SZFE2EKillHelpersUnder(NSArray<NSNumber *> *pids, NSString *directory);
// Waits until `pid` no longer exists; NO after `timeout`.
BOOL SZFE2EWaitGone(pid_t pid, NSTimeInterval timeout);

NS_ASSUME_NONNULL_END
