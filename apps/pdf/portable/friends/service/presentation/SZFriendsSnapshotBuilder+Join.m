// Shenzhen Friends snapshot builder: joining a profile (SZFriendsPresentationJoin.h, PROTOCOL.md § Joining).

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationJoin.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsJoinRequestFacts
@end

@implementation SZFriendsJoiningFacts
@end

static NSString *const SZFriendsJoinStateNames[] = {
    @"idle", @"waiting", @"checking", @"wrong_code", @"not_reached", @"denied", @"expired", @"too_many_attempts",
    @"joined", @"unavailable",
};

@implementation SZFriendsStrings (SZFriendsJoin)

- (NSString *)joinMessageForErrorCode:(NSString *)code field:(NSString *)field {
    if ([code isEqualToString:@"not_found"]) return [self text:@"error.not_found.join"];
    if ([code isEqualToString:@"not_allowed"]) return [self text:@"error.not_allowed.join"];
    if ([code isEqualToString:@"invalid_field"] && [field isEqual:@"code"]) {
        return [self text:@"error.invalid_field.code"];
    }
    return nil;
}

@end

@implementation SZFriendsSnapshotBuilder (SZFriendsJoin)

// "4831 2207": two groups of four, as people read a code aloud.
- (NSString *)groupedJoinCode:(NSString *)code {
    if (code.length != 8) return code;
    return [NSString stringWithFormat:@"%@ %@", [code substringToIndex:4], [code substringFromIndex:4]];
}

// "4 8 3 1, 2 2 0 7": digit by digit, so a screen reader never says "forty-eight million".
- (NSString *)spokenJoinCode:(NSString *)code {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger start = 0; start < code.length; start += 4) {
        NSString *group = [code substringWithRange:NSMakeRange(start, MIN(4, code.length - start))];
        NSMutableArray<NSString *> *digits = [NSMutableArray array];
        for (NSUInteger i = 0; i < group.length; i++) [digits addObject:[group substringWithRange:NSMakeRange(i, 1)]];
        [groups addObject:[digits componentsJoinedByString:@" "]];
    }
    return [groups componentsJoinedByString:@", "];
}

- (NSDictionary<NSString *, id> *)joinRowWithFacts:(SZFriendsJoinRequestFacts *)facts now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    // A phone asking says so ("Android phone"), where a computer's system shows as it is.
    NSDictionary<NSString *, NSString *> *names = @{@"device" : facts.deviceName,
                                                   @"system" : [s deviceSystemLabel:facts.system]};
    NSMutableDictionary<NSString *, id> *row = [@{
        @"join_id" : facts.joinID,
        @"code" : [NSNull null],
        @"code_accessibility_label" : [NSNull null],
        @"code_note" : [NSNull null],
    } mutableCopy];
    BOOL approved = facts.approved && facts.code.length > 0 && facts.codeExpiresAt != nil &&
                    [facts.codeExpiresAt compare:now] == NSOrderedDescending;
    if (!approved) {
        NSMutableDictionary *approve = [self action:@"approve_join" label:[s text:@"join.row.approve"]
                                              style:@"primary"];
        approve[@"join_id"] = facts.joinID;
        NSMutableDictionary *deny = [self action:@"deny_join" label:[s text:@"join.row.deny"] style:@"secondary"];
        deny[@"join_id"] = facts.joinID;
        // A stray click would turn the person's own new computer away, so Deny asks for a second one.
        deny[@"arm"] = @{
            @"label" : [s text:@"join.row.deny.arm"],
            @"accessibility_label" : [s text:@"join.row.deny.arm.accessibility" values:names],
            @"seconds" : @4,
        };
        row[@"state"] = @"waiting";
        row[@"title"] = [s text:@"join.row.title" values:names];
        row[@"subtitle"] = [s text:@"join.row.subtitle" values:names];
        row[@"actions"] = @[ approve, deny ];
        row[@"accessibility_label"] = [s text:@"join.row.accessibility" values:names];
        return row;
    }
    NSMutableDictionary<NSString *, NSString *> *values = [names mutableCopy];
    values[@"time"] = [s clockLabelForDate:facts.codeExpiresAt];
    values[@"code"] = [self spokenJoinCode:facts.code];
    NSMutableDictionary *cancel = [self action:@"deny_join" label:[s text:@"join.row.approved.cancel"]
                                         style:@"secondary"];
    cancel[@"join_id"] = facts.joinID;
    row[@"state"] = @"approved";
    row[@"title"] = [s text:@"join.row.approved.title" values:values];
    row[@"subtitle"] = [s text:@"join.row.approved.subtitle" values:values];
    row[@"code"] = [self groupedJoinCode:facts.code];
    row[@"code_accessibility_label"] = values[@"code"];
    row[@"code_note"] = [s text:@"join.row.approved.note" values:values];
    row[@"actions"] = @[ cancel ];
    row[@"accessibility_label"] = [s text:@"join.row.approved.accessibility" values:values];
    return row;
}

- (NSArray<NSDictionary<NSString *, id> *> *)joinRequestRowsWithFacts:(NSArray<SZFriendsJoinRequestFacts *> *)facts
                                                                   now:(NSDate *)now {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:facts.count];
    for (SZFriendsJoinRequestFacts *request in facts) [rows addObject:[self joinRowWithFacts:request now:now]];
    return rows;
}

- (NSDictionary<NSString *, id> *)badgeWithPeople:(NSArray<SZFriendsPersonFacts *> *)people
                                     joinRequests:(NSArray<SZFriendsJoinRequestFacts *> *)joinRequests {
    NSInteger count = (NSInteger)joinRequests.count;
    for (SZFriendsPersonFacts *person in people) count += [self personWaits:person];
    SZFriendsStrings *s = self.strings;
    return @{
        @"count" : @(count),
        @"label" : [s badgeLabelForCount:count],
        @"accessibility_label" : count ? [s text:@"badge.accessibility" count:count values:nil]
                                       : [s text:@"static.button_label"],
    };
}

- (NSDictionary<NSString *, id> *)joinWithFacts:(SZFriendsJoiningFacts *)facts {
    SZFriendsStrings *s = self.strings;
    SZFriendsJoiningState state = facts.state;
    NSString *displayID = [s displayID:facts.friendsID];
    NSMutableDictionary<NSString *, id> *data = [@{
        @"state" : SZFriendsJoinStateNames[MIN(MAX(state, 0), SZFriendsJoiningUnavailable)],
        @"title" : [s text:@"join.title"],
        @"message" : [NSNull null],
        @"friends_id" : facts.friendsID ?: [NSNull null],
        @"id_field" : [NSNull null],
        @"code_field" : [NSNull null],
        @"error" : [NSNull null],
        @"actions" : @[],
    } mutableCopy];
    NSMutableDictionary *cancel = [self action:@"cancel_join" label:[s text:@"join.cancel"] style:@"secondary"];
    NSMutableDictionary *again = [self action:@"join_profile" label:[s text:@"join.start_again"] style:@"primary"];
    again[@"friends_id"] = facts.friendsID ?: @"";
    NSDictionary *codeField = @{
        @"length" : @8,
        @"placeholder" : [s text:@"join.code.placeholder"],
        @"button" : [s text:@"join.code.button"],
        @"enabled" : SZFriendsBool(state != SZFriendsJoiningChecking),
    };
    switch (state) {
    case SZFriendsJoiningIdle:
        data[@"message"] = [s text:@"join.idle.message"];
        data[@"id_field"] = @{
            @"placeholder" : [s text:@"join.idle.placeholder"],
            @"button" : [s text:@"join.idle.button"],
        };
        break;
    case SZFriendsJoiningWaiting:
    case SZFriendsJoiningChecking:
    case SZFriendsJoiningWrongCode:
    case SZFriendsJoiningNotReached:
        data[@"title"] = [s text:@"join.waiting.title"];
        data[@"message"] = state == SZFriendsJoiningChecking ? [s text:@"join.checking.message"]
                                                             : [s text:@"join.waiting.message"
                                                                values:@{@"id" : displayID}];
        data[@"code_field"] = codeField;
        if (state == SZFriendsJoiningWrongCode) data[@"error"] = [s text:@"join.wrong_code"];
        if (state == SZFriendsJoiningNotReached) data[@"error"] = [s text:@"join.not_reached"];
        data[@"actions"] = @[ cancel ];
        break;
    case SZFriendsJoiningDenied:
    case SZFriendsJoiningExpired:
    case SZFriendsJoiningTooManyAttempts: {
        NSString *key = state == SZFriendsJoiningDenied ? @"join.denied"
                        : state == SZFriendsJoiningExpired ? @"join.expired" : @"join.too_many";
        data[@"title"] = [s text:[key stringByAppendingString:@".title"]];
        data[@"message"] = [s text:[key stringByAppendingString:@".message"]];
        data[@"actions"] = facts.friendsID.length ? @[ again, cancel ] : @[ cancel ];
        break;
    }
    case SZFriendsJoiningJoined:
        data[@"title"] = [s text:@"join.joined.title"];
        data[@"message"] = [s text:@"join.joined.message"];
        break;
    case SZFriendsJoiningUnavailable:
        data[@"message"] = [s text:@"join.unavailable.message"];
        break;
    }
    return data;
}

@end
