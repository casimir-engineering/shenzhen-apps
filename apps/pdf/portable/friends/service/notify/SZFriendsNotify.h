// Shenzhen Friends system notifications on a Mac (ADR 0017, PROTOCOL.md § Notifications): the helper decides, once,
// when an item is first committed to this Mac's store, whether the person hears about it, and a poster shows it.
//
// Helper-only. The helper owns the store and the single-instance lock, so one process per Mac posts whatever app the
// person uses Friends from; views never post. Three parts:
//   - SZFriendsNotifier decides and words each notification (the request of ADR 0017 § The request), coalesces bursts
//     and batches, withdraws a conversation's notifications once it is read, and routes clicks and replies;
//   - a poster shows them: SZFriendsNotifySystemPoster through UNUserNotificationCenter, or, in a test home
//     (SZFRIENDS_STATE_DIR), SZFriendsNotifyFileSink, which appends JSON lines to <state dir>/notifications.jsonl and
//     never touches the notification centre;
//   - SZFriendsNotifySettings, this Mac's switches and the app a click opens, kept in the state directory and never
//     synced: a person may want message text on the Mac but not on a phone's lock screen.
//
// Everything runs on the helper's queue (the main queue), like the rest of the helper.

#import <Foundation/Foundation.h>

#import "service/presentation/SZFriendsPresentationNotifications.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Settings

// What a click opens: the app the person last used Friends from (ADR 0017 § Where a click goes).
@interface SZFriendsNotifyTarget : NSObject <NSCopying>
@property(nonatomic, copy) NSString *appID;              // "com.intuition.shenzhenpdf"
@property(nonatomic, copy) NSString *urlScheme;          // "shenzhenpdf"
@property(nonatomic, copy, nullable) NSString *appPath;  // "/Applications/ShenzhenPDF.app"; nil when unknown
// ShenzhenPDF, which every Mac with Friends has, until the person uses Friends from an app.
+ (instancetype)defaultTarget;
// <scheme>://friends/conversation/<id>, or <scheme>://friends without a conversation (a join request).
- (NSString *)URLForConversation:(nullable NSString *)conversationID;
@end

// The URL scheme of an app Friends runs in, from its app id, for a client whose hello named none; nil for others.
NSString *_Nullable SZFriendsNotifyKnownScheme(NSString *appID);
// The .app bundle an executable belongs to (…/X.app/Contents/MacOS/x -> …/X.app); nil when it is not an app's.
NSString *_Nullable SZFriendsNotifyBundlePath(NSString *_Nullable executablePath);

// This Mac's notification switches, <state dir>/notify-settings.json, and the target, <state dir>/notify-target.
@interface SZFriendsNotifySettings : NSObject
- (instancetype)initWithStateDirectory:(NSString *)stateDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic) BOOL enabled;      // Show notifications: on by default
@property(nonatomic) BOOL preview;      // Show message text: on by default
@property(nonatomic) BOOL askDismissed; // Not Now on the list's card
@property(nonatomic) BOOL used;         // the person has opened Friends on this Mac (activate)
@property(nonatomic, copy) SZFriendsNotifyTarget *target;
@end

#pragma mark - Posters

typedef NS_ENUM(NSInteger, SZFriendsNotifyPermission) {
    SZFriendsNotifyPermissionGranted = 0,
    SZFriendsNotifyPermissionDenied = 1,
    SZFriendsNotifyPermissionNotAsked = 2,
};

// A click or a reply: `action` "open" or "reply" (with `text`), for the notification `key`; `request` is what was
// posted (the system hands it back with the response), nil when the poster no longer has it.
typedef void (^SZFriendsNotifyResponseHandler)(NSString *key, NSString *action, NSString *_Nullable text,
                                               NSDictionary<NSString *, id> *_Nullable request);

@protocol SZFriendsNotificationPoster <NSObject>
// One request as ADR 0017 § The request gives it (key, kind, channel, conversation_id, thread, title, body, time,
// reply, open).
- (void)post:(NSDictionary<NSString *, id> *)request;
// Removes every delivered notification of one thread (a conversation read here or on another device).
- (void)withdrawThread:(NSString *)thread;
@property(nonatomic, readonly) SZFriendsNotifyPermission permission;
// allow_notifications: asks the system once; `completion` runs on the helper's queue when the answer is known.
- (void)askWithCompletion:(void (^)(void))completion;
// Opens `url` in the app at `appPath` (activating it), else with the scheme's default app, else in ShenzhenPDF.
- (void)openURL:(NSString *)url appID:(NSString *)appID appPath:(nullable NSString *)appPath;
// Clicks and replies from the system, on the helper's queue.
@property(nonatomic, copy, nullable) SZFriendsNotifyResponseHandler onResponse;
// The system's answer changed (asked, or changed in System Settings): Settings and the card are shown again.
@property(nonatomic, copy, nullable) void (^onPermissionChange)(void);
@end

// The test home's poster: one JSON object per line in <state dir>/notifications.jsonl (requests, {"withdraw":…},
// {"asked":true}, {"opened":…}). Its permission is SZFRIENDS_NOTIFY_PERMISSION (granted, denied, not_asked; granted
// by default); asking turns not_asked into granted, as a person pressing Allow would.
@interface SZFriendsNotifyFileSink : NSObject <SZFriendsNotificationPoster>
- (instancetype)initWithStateDirectory:(NSString *)stateDirectory
                           environment:(NSDictionary<NSString *, NSString *> *)environment NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSString *path;
@end

// The real poster: UNUserNotificationCenter, the conversation as the thread, Reply on messages, LaunchServices for
// clicks. Only a helper outside a test home makes one; no test process ever does.
@interface SZFriendsNotifySystemPoster : NSObject <SZFriendsNotificationPoster>
- (instancetype)initWithQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// A helper macOS launched for a click or a reply while another helper holds the lock (ADR 0017): waits briefly for
// the response, then opens the URL itself (a click) or hands the reply to the running helper over its socket, as a
// client would, and returns. `stateDirectory` is the running helper's.
void SZFriendsNotifyForwardLaunchResponse(NSString *stateDirectory);

#pragma mark - The notifier

@interface SZFriendsNotifier : NSObject
- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(nullable SZFriendsTransfers *)transfers
                     settings:(SZFriendsNotifySettings *)settings
                       poster:(id<SZFriendsNotificationPoster>)poster
                        queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) SZFriendsNotifySettings *settings;
@property(nonatomic, readonly) id<SZFriendsNotificationPoster> poster;
// A test home's poster: test_notification_response is accepted only then.
@property(nonatomic, readonly) BOOL testHome;
// The conversations a focused window shows now (set_focus, or an open conversation of an older app): never notified.
@property(nonatomic, copy, nullable) NSSet<NSString *> * (^focusedConversations)(void);
// A reply to send in a conversation (as send_message would) and mark read; set by the helper.
@property(nonatomic, copy, nullable) void (^sendReply)(NSString *conversationID, NSString *text);
// How long a burst lasts: messages (and offers) committed within it make one notification. 1 s; tests may shorten.
@property(nonatomic) NSTimeInterval burstInterval;

// What Settings and the card show.
- (SZFriendsNotificationsFacts *)facts;
// The last app the person used Friends from (activate, open_conversation, a non-null set_focus).
- (void)rememberAppID:(NSString *)appID urlScheme:(nullable NSString *)urlScheme appPath:(nullable NSString *)appPath;

#pragma mark Commit points: each called once, right after the item is first stored on this Mac

// A friend's message from their own device (not by sync).
- (void)noteMessage:(SZFriendsItemRecord *)item;
// A friend's offer: waiting for an answer, or accepted automatically (notified once received).
- (void)noteOffer:(SZFriendsTransferRecord *)transfer automatic:(BOOL)automatic;
// An incoming transfer was received whole: an automatically accepted one notifies (with its batch).
- (void)noteTransferReceived:(NSString *)transferID;
// Someone asked to be friends; this person's request was accepted; someone used this person's friend link (friends
// at once); this person used theirs and it went through.
- (void)noteRequestFrom:(SZFriendsPersonRecord *)person;
- (void)noteAcceptedBy:(SZFriendsPersonRecord *)person;
- (void)noteLinkUsedBy:(SZFriendsPersonRecord *)person;
- (void)noteLinkAddedWith:(SZFriendsPersonRecord *)person;
// A computer or phone asks to join this person's profile.
- (void)noteJoinRequest:(NSString *)joinID deviceName:(NSString *)deviceName;
// Items another of the person's devices synced here (already committed, unread counts recounted).
- (void)noteSyncedItems:(NSArray<SZFriendsItemRecord *> *)items;

#pragma mark Reads and responses

// Withdraws the notifications of conversations read since they were posted; the helper calls it after each change.
- (void)withdrawReadConversations;
// A click (`open`) or a reply on a notification posted earlier. NO when the key names nothing this helper posted.
- (BOOL)respondToKey:(NSString *)key action:(NSString *)action text:(nullable NSString *)text;
// allow_notifications.
- (void)askWithCompletion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
