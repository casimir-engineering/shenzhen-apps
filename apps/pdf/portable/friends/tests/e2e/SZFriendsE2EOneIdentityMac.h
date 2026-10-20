// friends-one-identity-check, one computer: what the scenarios on Ana's Mac share (SZFriendsE2EOneIdentity.h). Her
// home with nothing that says where Friends lives, the three apps built around the oneid helper, launching and quitting
// them, and asking them what their views show.

#import "SZFriendsE2EOneIdentity.h"

NS_ASSUME_NONNULL_BEGIN

// The apps by the names the scenarios use, and the build their helpers say unless a scenario changes it.
extern NSString *const SZFOPDF, *const SZFOFiles, *const SZFO3D;
extern const uint64_t SZFOBuild;
NSArray<NSString *> *SZFOApps(void);
// Every order the three can start in.
NSArray<NSArray<NSString *> *> *SZFOOrders(void);

// Ana's Mac: one home, the three app bundles, and the apps running now.
@interface SZFOMac : NSObject
@property(nonatomic, copy) NSString *home, *appsDirectory, *friendsID;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *executables, *helpers;
@property(nonatomic) NSMutableDictionary<NSString *, SZFE2EApp *> *running;
@property(nonatomic) NSMutableSet<NSNumber *> *helperPIDs;
@property(nonatomic, nullable) SZFE2EComputer *ben, *laptop;
@property(nonatomic, copy, nullable) NSString *benAtAna, *anaAtBen;
@end

// Where the shipped apps put the Friends home of a person whose home is `home`.
NSString *SZFOStateDirectory(NSString *home);
// Ana befriends Ben on her Friends home (Ben's message left unread), with `laptop` a second computer of hers joins (so
// You exists), and the three app bundles are made with `builds`. Nil, with a failure recorded, when anything fails.
SZFOMac *_Nullable SZFOPrepareWith(SZFE2EWorld *world, NSDictionary<NSString *, NSNumber *> *builds, BOOL laptop);
SZFOMac *_Nullable SZFOPrepare(SZFE2EWorld *world, NSDictionary<NSString *, NSNumber *> *builds);
NSDictionary<NSString *, NSNumber *> *SZFOSameBuild(void);
// Changes the build an app's embedded helper says (the app updated to a newer or older one).
BOOL SZFOSetBuild(SZFOMac *mac, NSString *app, uint64_t build);
// Every Friends helper process running from one of the Mac's app bundles.
NSArray<NSNumber *> *SZFOHelperProcesses(SZFOMac *mac);
SZFE2EApp *_Nullable SZFOLaunch(SZFOMac *mac, NSString *app, uint64_t build);
void SZFOQuitAll(SZFOMac *mac);
// Quits the apps and stops every helper of the Mac; with `printLogs`, their logs' ends first.
void SZFOShutDown(SZFOMac *mac, BOOL printLogs);
void SZFODrain(SZFOMac *mac);
// The pid every running app is ready on when they all agree, else 0; waits for that.
pid_t SZFOSharedHelper(SZFOMac *mac);
BOOL SZFOAllReady(SZFOMac *mac, NSTimeInterval timeout);
NSString *SZFOStates(SZFOMac *mac);
// A command with a tag of its own; its reply, or nil after `timeout`.
NSDictionary *_Nullable SZFOAsk(SZFE2EApp *app, NSDictionary *command, NSTimeInterval timeout);
// What the app's real conversation view shows (`title` is the row's, for Shenzhen 3D's panel), nil when it failed.
NSArray<NSString *> *_Nullable SZFOShownTexts(SZFE2EApp *app, NSString *conversationID, NSString *title);
BOOL SZFOShows(NSArray<NSString *> *_Nullable texts, NSString *text);
// Waits until the real view of each of `apps` shows `text` in the conversation (or, `shown` NO, no longer does).
BOOL SZFOViewsShow(SZFOMac *mac, NSArray<NSString *> *apps, NSString *conversationID, NSString *title, NSString *text,
                   BOOL shown, NSTimeInterval timeout);
NSDictionary *_Nullable SZFORow(SZFE2EApp *app, NSString *conversationID);
// Every app subscribed to its list and profile; waits until each says Ana's one Friends ID and `name`.
BOOL SZFOSameIdentity(SZFOMac *mac, NSString *name);
// Exactly one helper process, `helper`, with every app on it, through `seconds` of looking.
BOOL SZFOOnlyHelper(SZFOMac *mac, pid_t helper, NSTimeInterval seconds);

NS_ASSUME_NONNULL_END
