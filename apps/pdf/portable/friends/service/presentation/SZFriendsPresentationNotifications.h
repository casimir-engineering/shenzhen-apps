// System notifications as the person reads them (PROTOCOL.md § Notifications, ADR 0017): the words of each
// notification, Settings' Notifications block and the list's card that offers to turn them on.
//
// Pure, like SZFriendsPresentation.h: facts in, display-ready text out. Two readers. A notification is glanced at
// while the person does something else: its title says who, its body what, in the list's words. Settings and the
// card speak to someone deciding whether Friends may interrupt them.

#import "service/presentation/SZFriendsPresentation.h"

NS_ASSUME_NONNULL_BEGIN

// What the system allows this device's notifications.
typedef NS_ENUM(NSInteger, SZFriendsNotifyPermissionFacts) {
    SZFriendsNotifyPermissionFactsGranted = 0,
    SZFriendsNotifyPermissionFactsDenied = 1,
    SZFriendsNotifyPermissionFactsNotAsked = 2,
    SZFriendsNotifyPermissionFactsNotNeeded = 3,   // Windows, Linux: nothing to ask
    SZFriendsNotifyPermissionFactsUnavailable = 4, // Linux without a notification service
};

// This device's notification switches and where the system stands; never synced.
@interface SZFriendsNotificationsFacts : NSObject
@property(nonatomic) BOOL enabled;      // Show notifications
@property(nonatomic) BOOL preview;      // Show message text
@property(nonatomic) SZFriendsNotifyPermissionFacts permission;
@property(nonatomic) BOOL askDismissed; // Not Now on the list's card
@property(nonatomic) BOOL used;         // the person has opened Friends on this device (activate)
@end

@interface SZFriendsSnapshotBuilder (SZFriendsNotifications)
// settings.notifications, for an audience whose helper announces `notifications`; nil otherwise.
- (nullable NSDictionary<NSString *, id> *)notificationsSettingsWithFacts:(SZFriendsNotificationsFacts *)facts;
// The list's `notifications` banner for an audience that declared notifications.ask, while the system has not been
// asked, notifications are on, the person has used Friends here and has not chosen Not Now; nil otherwise.
- (nullable NSDictionary<NSString *, id> *)notificationsBannerWithFacts:(SZFriendsNotificationsFacts *)facts;
@end

@interface SZFriendsStrings (SZFriendsNotifications)
// Who a notification is from: the friend's name as the list shows it.
- (NSString *)notificationTitleForName:(nullable NSString *)name friendsID:(nullable NSString *)friendsID;
// A message's body: its text with mentions as their names, or "New message" / "3 new messages" when `text` is nil
// (Show message text off).
- (NSString *)notificationBodyForMessageText:(nullable NSString *)text count:(NSUInteger)count;
// Files offered or received together: "Mei wants to send you Bracket.step and 2 more files", "Mei sent a file".
// `fileNames` nil hides them (Show message text off); `count` is how many files there are.
- (NSString *)notificationBodyForFiles:(nullable NSArray<NSString *> *)fileNames
                                 count:(NSUInteger)count
                                sender:(NSString *)name
                               offered:(BOOL)offered;
// notify.request, notify.accepted, notify.link.used, notify.link.added, notify.reply, notify.reply.send.
- (NSString *)notificationText:(NSString *)key;
- (NSString *)notificationReplyPlaceholderForName:(NSString *)name; // "Message Mei"
- (NSString *)notificationJoinTitleForDevice:(NSString *)deviceName; // "Pixel 8 wants to join your profile"
@end

NS_ASSUME_NONNULL_END
