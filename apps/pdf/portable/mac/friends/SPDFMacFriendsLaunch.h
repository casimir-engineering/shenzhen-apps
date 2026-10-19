// The one piece of Friends work on ShenzhenPDF's launch path: a non-blocking helper spawn, off the main thread.
//
// Brief § Product contract and ADR 0002: while Friends is enabled the launching reader spawns the helper from a
// background queue at once, without waiting for or delaying its first window; while disabled nothing runs (no
// queue hop, spawn, socket, timer or Friends file access). Everything else (the helper link, the button, the
// badge) attaches after first paint. The spawn and the queue hop are injectable so a test can prove both halves
// of that sentence on an instrumented environment rather than by reading the source.

#import <Foundation/Foundation.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

// Returns a szfriends_status (0 is SZFRIENDS_OK). `stateDirectory` nil means the client library's default, which
// honours SZFRIENDS_STATE_DIR.
typedef int (^SPDFMacFriendsSpawnFunction)(NSString* helperPath, NSString* _Nullable stateDirectory, pid_t* pid);

@interface SPDFMacFriendsLaunchEnvironment : NSObject
// Default: dispatch_async to the utility-QoS global queue. A global queue, not a new one, so an enabled launch
// creates no queue of its own either.
@property(nonatomic, copy) void (^dispatchBackground)(dispatch_block_t block);
// Production: the client library's connect-or-spawn, szfriends_spawn_helper() (SPDFMacFriendsLaunchDefault.mm).
@property(nonatomic, copy) SPDFMacFriendsSpawnFunction spawn;
// Runs before the launch spawn (on its background queue) and before every attach (on the main thread), so the
// client library knows a signed app's signing policy before it spawns or connects (SPDFMacFriendsSigning.h). It
// must be idempotent; production sets the policy once and later calls return at once. nil: nothing to set.
@property(nonatomic, copy, nullable) dispatch_block_t prepareSigning;
- (instancetype)initWithSpawn:(SPDFMacFriendsSpawnFunction)spawn NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// The production environment (SPDFMacFriendsLaunchDefault.mm, linked only into the app).
SPDFMacFriendsLaunchEnvironment* SPDFMacFriendsDefaultLaunchEnvironment(void);

// The launch hook. Disabled: returns NO having done nothing at all. Enabled: one dispatch to the background, where
// the signing policy is prepared, `helperPath` is evaluated (bundle lookups stay off the main thread too) and the
// spawn runs; returns YES at once.
BOOL SPDFMacFriendsSpawnAtLaunch(BOOL enabled, NSString* _Nullable (^helperPath)(void),
                                 SPDFMacFriendsLaunchEnvironment* environment);

@class SPDFMacFriendsSettingsState;

// One reader process's Friends lifecycle: spawn at launch, attach after first paint, attach or detach when the
// setting changes. `attach` creates the helper link, the dropdown and the button; `detach` takes them down (with
// `disabling` YES the link first tells the helper this app turned Friends off). Neither runs while disabled, so a
// disabled reader never creates a link, socket or timer. The environment's prepareSigning runs before each attach.
@interface SPDFMacFriendsLifecycle : NSObject
- (instancetype)initWithSettings:(SPDFMacFriendsSettingsState*)settings
                     environment:(SPDFMacFriendsLaunchEnvironment*)environment
                      helperPath:(NSString* _Nullable (^)(void))helperPath
                          attach:(void (^)(void))attach
                          detach:(void (^)(BOOL disabling))detach NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// loadPersistentState's parsed settings.yaml: records the setting and, when enabled, spawns in the background.
- (void)launchWithSettings:(nullable NSDictionary*)settings;
// The first frame is on screen: attach when enabled. Idempotent.
- (void)firstPaintDidHappen;
// This window's Settings checkbox. Records the choice; the caller saves settings.yaml and tells other windows.
- (void)setEnabled:(BOOL)enabled;
// Another window changed settings.yaml: follow it.
- (void)settingsDidChange:(nullable NSDictionary*)settings;
@property(nonatomic, readonly, getter=isAttached) BOOL attached;
@end

// The helper executable this app embeds: Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends.
// nil when the bundle does not carry it (a development build run before the helper is embedded), so the reader
// spawns nothing rather than failing.
NSString* _Nullable SPDFMacFriendsHelperExecutablePath(NSBundle* bundle);
FOUNDATION_EXPORT NSString* const SPDFMacFriendsHelperBundleName;   // "Shenzhen Friends.app"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsHelperExecutableName; // "Shenzhen Friends"

NS_ASSUME_NONNULL_END
