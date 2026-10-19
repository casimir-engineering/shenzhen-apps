// Shenzhen Friends snapshot builder: links (PROTOCOL.md § Links). The profile's "Your links", the cards open_link
// answers with, and the messages after Add, Download and Copy Download Link.

#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsLinksWords)

// Whole calendar days from `now` to `date` in the reader's time zone: 0 today, 1 tomorrow.
- (NSInteger)daysFrom:(NSDate *)now to:(NSDate *)date {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = self.audience.timeZone;
    NSDate *start = [calendar startOfDayForDate:now], *end = [calendar startOfDayForDate:date];
    return MAX([calendar components:NSCalendarUnitDay fromDate:start toDate:end options:0].day, 0);
}

- (NSString *)expiryLabelFor:(NSDate *)expiresAt now:(NSDate *)now {
    NSInteger days = [self daysFrom:now to:expiresAt];
    if (days == 0) return [self.strings text:@"links.expires.today"];
    if (days == 1) return [self.strings text:@"links.expires.tomorrow"];
    return [self.strings text:@"links.expires.days" count:days values:nil];
}

- (NSDictionary<NSString *, id> *)downloadRowForLink:(SZFriendsDownloadLinkFacts *)link now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *revoke = [self action:@"revoke_link" label:[s text:@"links.revoke"] style:@"link"];
    revoke[@"link_id"] = link.linkID;
    return @{
        @"link_id" : link.linkID,
        @"file_name" : link.fileName,
        @"downloads_label" : link.downloads == 0 ? [s text:@"links.downloads.none"]
                                                 : [s text:@"links.downloads.count" count:(NSInteger)link.downloads
                                                    values:nil],
        @"expires_label" : [self expiryLabelFor:link.expiresAt now:now],
        @"revoke" : revoke,
    };
}

@end

@implementation SZFriendsSnapshotBuilder (SZFriendsLinksSection)

- (nullable id)linksSectionWithFacts:(nullable SZFriendsLinksFacts *)links {
    if (links == nil || links.friendURL.length == 0 || ![self.audience.helperCapabilities containsObject:@"links"]) {
        return nil;
    }
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *reset = [self action:@"reset_friend_link" label:[s text:@"links.friend.reset"]
                                        style:@"secondary"];
    reset[@"confirm"] = [self confirmWithTitle:@"links.friend.reset.confirm.title"
                                          body:@"links.friend.reset.confirm.body"
                                  confirmLabel:@"links.friend.reset.confirm.button"
                                        values:@{}
                                   destructive:YES];
    NSMutableArray *downloads = [NSMutableArray array];
    for (SZFriendsDownloadLinkFacts *link in links.downloads) {
        [downloads addObject:[self downloadRowForLink:link now:links.now]];
    }
    return @{
        @"title" : [s text:@"links.title"],
        @"friend" : @{
            @"label" : [s text:@"links.friend.label"],
            @"url" : links.friendURL,
            @"note" : [s text:@"links.friend.note"],
            @"copy_label" : [s text:@"static.copy"],
            @"reset" : reset,
        },
        @"downloads_label" : [s text:@"links.downloads.label"],
        @"downloads_empty" : downloads.count ? [NSNull null] : [s text:@"links.downloads.empty"],
        @"downloads" : downloads,
    };
}

@end

@implementation SZFriendsSnapshotBuilder (SZFriendsLinks)

#pragma mark - Cards and messages

- (NSDictionary<NSString *, id> *)friendLinkCardWithName:(NSString *)name
                                               friendsID:(NSString *)friendsID
                                                 payload:(NSString *)payload
                                           alreadyFriend:(BOOL)alreadyFriend {
    SZFriendsStrings *s = self.strings;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *who = trimmed.length ? trimmed : [s displayID:friendsID];
    NSDictionary *values = @{@"name" : who, @"id" : [s displayID:friendsID]};
    NSMutableDictionary *add = [self action:@"add_from_link" label:[s text:@"link.friend.add"] style:@"primary"];
    add[@"payload"] = payload;
    return @{
        @"kind" : @"friend",
        @"title" : [s text:alreadyFriend ? @"link.friend.already" : @"link.friend.title" values:values],
        @"subtitle" : [s text:@"link.friend.subtitle" values:values],
        @"note" : alreadyFriend ? [NSNull null] : [s text:@"link.friend.note" values:values],
        @"avatar" : [self avatarForPicture:[SZFriendsPicture placeholder] seed:friendsID
                               displayName:trimmed.length ? trimmed : friendsID],
        @"actions" : alreadyFriend ? @[] : @[ add ],
    };
}

- (NSDictionary<NSString *, id> *)downloadLinkCardWithPayload:(NSString *)payload {
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *download = [self action:@"receive_link" label:[s text:@"link.download.action"]
                                           style:@"primary"];
    download[@"payload"] = payload;
    return @{
        @"kind" : @"download",
        @"title" : [s text:@"link.download.title"],
        @"subtitle" : [NSNull null],
        @"note" : [s text:@"link.download.note"],
        @"avatar" : [NSNull null],
        @"actions" : @[ download ],
    };
}

- (NSString *)linkRequestSentMessageForName:(NSString *)name {
    return [self linkRequestSentMessageForName:name online:NO];
}

- (NSString *)linkRequestSentMessageForName:(NSString *)name online:(BOOL)online {
    return [self.strings text:online ? @"link.request_sent.online" : @"link.request_sent" values:@{@"name" : name}];
}

- (NSString *)linkReceivingMessageForFile:(NSString *)fileName sender:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return [self.strings text:@"link.receiving.anonymous" values:@{@"file" : fileName}];
    NSString *first = [self.strings firstNameForName:trimmed friendsID:nil];
    return [self.strings text:@"link.receiving" values:@{@"file" : fileName, @"name" : trimmed, @"first" : first}];
}

- (NSString *)downloadLinkMadeMessageUntil:(NSDate *)expiresAt {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    formatter.timeZone = self.audience.timeZone;
    formatter.dateFormat = @"d MMMM";
    return [self.strings text:@"link.made" values:@{@"date" : [formatter stringFromDate:expiresAt]}];
}

@end
