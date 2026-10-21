// Shenzhen Friends snapshot builder: system notifications' words, Settings' Notifications block and the list's card
// (SZFriendsPresentationNotifications.h).

#import "service/presentation/SZFriendsMentions.h"
#import "service/presentation/SZFriendsPresentationNotifications.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsNotificationsFacts
@end

@implementation SZFriendsSnapshotBuilder (SZFriendsNotifications)

- (nullable NSDictionary<NSString *, id> *)notificationsSettingsWithFacts:(SZFriendsNotificationsFacts *)facts {
    if (![self.audience.helperCapabilities containsObject:@"notifications"]) return nil;
    SZFriendsStrings *s = self.strings;
    id note = @"", action = [NSNull null];
    switch (facts.permission) {
    case SZFriendsNotifyPermissionFactsNotAsked:
        note = [s text:@"settings.notifications.note.not_asked"];
        action = [self action:@"allow_notifications" label:[s text:@"settings.notifications.allow"]
                        style:@"secondary"];
        break;
    case SZFriendsNotifyPermissionFactsDenied: {
        note = [s text:@"settings.notifications.note.denied.mac"];
        NSMutableDictionary *open = [self action:@"open_settings"
                                           label:[s text:@"settings.notifications.open_settings.mac"]
                                           style:@"secondary"];
        open[@"settings_target"] = @"notifications";
        action = open;
        break;
    }
    case SZFriendsNotifyPermissionFactsUnavailable:
        note = [s text:@"settings.notifications.note.unavailable"];
        break;
    case SZFriendsNotifyPermissionFactsGranted:
    case SZFriendsNotifyPermissionFactsNotNeeded:
        break;
    }
    return @{
        @"label" : [s text:@"settings.notifications.label"],
        @"enabled" : @{@"label" : [s text:@"settings.notifications.enabled"], @"value" : SZFriendsBool(facts.enabled)},
        @"preview" : @{
            @"label" : [s text:@"settings.notifications.preview"],
            @"note" : [s text:@"settings.notifications.preview.note"],
            @"value" : SZFriendsBool(facts.preview)
        },
        @"note" : note,
        @"action" : action
    };
}

- (nullable NSDictionary<NSString *, id> *)notificationsBannerWithFacts:(SZFriendsNotificationsFacts *)facts {
    if (![self.audience.helperCapabilities containsObject:@"notifications"] ||
        ![self.audience.capabilities containsObject:@"notifications.ask"]) {
        return nil;
    }
    if (facts.permission != SZFriendsNotifyPermissionFactsNotAsked || !facts.enabled || facts.askDismissed ||
        !facts.used) {
        return nil;
    }
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *dismiss = [self action:@"dismiss_banner" label:[s text:@"banner.notifications.dismiss"]
                                          style:@"link"];
    dismiss[@"kind"] = @"notifications";
    return @{
        @"kind" : @"notifications",
        @"text" : [s text:@"banner.notifications.text"],
        @"action" : [self action:@"allow_notifications" label:[s text:@"banner.notifications.allow"] style:@"primary"],
        @"dismiss" : dismiss
    };
}

@end

@implementation SZFriendsStrings (SZFriendsNotifications)

- (NSString *)notificationTitleForName:(nullable NSString *)name friendsID:(nullable NSString *)friendsID {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) return trimmed;
    return friendsID.length ? [self displayID:friendsID] : [self text:@"person.unnamed"];
}

// A mention reads as its name ("@Mei Lin"), as the conversation shows it; every other word as it was written.
static NSString *SZFriendsPlainMessageText(NSString *text) {
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(text);
    if (links.count == 0) return text;
    NSMutableString *plain = [text mutableCopy];
    for (SZFriendsTextLink *link in links.reverseObjectEnumerator) {
        [plain replaceCharactersInRange:link.range withString:link.shownText];
    }
    return plain;
}

- (NSString *)notificationBodyForMessageText:(nullable NSString *)text count:(NSUInteger)count {
    if (text != nil) return SZFriendsPlainMessageText(text);
    return [self text:@"notify.message.hidden" count:(NSInteger)MAX(count, (NSUInteger)1) values:nil];
}

- (NSString *)notificationBodyForFiles:(nullable NSArray<NSString *> *)fileNames
                                 count:(NSUInteger)count
                                sender:(NSString *)name
                               offered:(BOOL)offered {
    NSString *base = offered ? @"notify.file.offer" : @"notify.file.received";
    if (fileNames.count == 0) {
        return [self text:[base stringByAppendingString:@".hidden"] count:(NSInteger)MAX(count, (NSUInteger)1)
                   values:@{@"name" : name}];
    }
    NSDictionary *values = @{@"name" : name, @"file" : fileNames.firstObject};
    if (count <= 1) return [self text:base values:values];
    return [self text:[base stringByAppendingString:@".more"] count:(NSInteger)(count - 1) values:values];
}

- (NSString *)notificationText:(NSString *)key {
    return [self text:key];
}

- (NSString *)notificationReplyPlaceholderForName:(NSString *)name {
    return [self text:@"notify.reply.placeholder" values:@{@"name" : name}];
}

- (NSString *)notificationJoinTitleForDevice:(NSString *)deviceName {
    return [self text:@"notify.join.title" values:@{@"device" : deviceName}];
}

@end
