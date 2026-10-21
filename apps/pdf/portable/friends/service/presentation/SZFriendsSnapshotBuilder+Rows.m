// Shenzhen Friends snapshot builder: what a person's row carries besides its words. Its menu (client capability
// list.menu) with Remove's question, which a friend's details ask too, and how someone nearby was found (nearby.found),
// on Nearby's rows and a friend's list row. Split from the builder so each file stays under the size cap.

#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsRows)

// Remove, from the row's menu or a friend's details: what happens to this person, asked first. A friend is removed
// without being told, a request is declined or withdrawn, and anyone else only leaves the list; a blocked person stays
// blocked. With history, the person may also delete it there; otherwise the question says nothing about history.
- (NSDictionary<NSString *, id> *)removeConfirmForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSDictionary *who = @{@"first" : [self firstNameForPerson:person]};
    BOOL request = person.relation == SZFriendsPersonRelationOutgoingRequest;
    NSString *body = person.relation == SZFriendsPersonRelationFriend    ? @"remove.confirm.body.friend"
                     : person.relation == SZFriendsPersonRelationBlocked ? @"remove.confirm.body.blocked"
                     : request                                            ? @"remove.confirm.body.request"
                                                                          : @"remove.confirm.body";
    NSMutableDictionary *confirm = [@{
        @"title" : [s text:request ? @"remove.confirm.title.request" : @"remove.confirm.title" values:who],
        @"body" : [s text:body values:who],
        @"confirm_label" : [s text:request ? @"action.cancel_request" : @"remove.confirm.button"],
        @"cancel_label" : [s text:request ? @"remove.confirm.keep" : @"static.cancel"],
        @"destructive" : @YES
    } mutableCopy];
    if (person.lastPreviewItemID.length) {
        confirm[@"body"] = [@[ confirm[@"body"], [s text:@"remove.confirm.history" values:who] ]
            componentsJoinedByString:@" "];
        confirm[@"option"] = @{@"label" : [s text:@"remove.confirm.option"], @"field" : @"delete_history"};
    }
    return confirm;
}

// The row's menu (client capability list.menu), shown on right-click, Control-click or long-press: Remove for
// everyone, worded as cancelling for a request this person sent.
- (NSArray<NSDictionary<NSString *, id> *> *)rowMenuForPerson:(SZFriendsPersonFacts *)person {
    BOOL request = person.relation == SZFriendsPersonRelationOutgoingRequest;
    NSMutableDictionary *remove = [self action:@"remove_friend"
                                         label:[self.strings text:request ? @"action.cancel_request" : @"menu.remove"]
                                         style:@"destructive"];
    remove[@"note"] = [NSNull null];
    remove[@"arm"] = [NSNull null];
    remove[@"confirm"] = [self removeConfirmForPerson:person];
    return @[ remove ];
}

#pragma mark - Found nearby

- (BOOL)showsFound {
    return [self.audience.capabilities containsObject:@"nearby.found"];
}

// Every method that sees the person, in the order lan, p2p_wifi, bluetooth, each once, named the way Nearby's methods
// are ("Local network and Bluetooth"); null while nothing sees them.
- (id)foundWithMethods:(nullable NSArray<NSNumber *> *)methods {
    SZFriendsStrings *s = self.strings;
    NSMutableArray<NSString *> *names = [NSMutableArray array], *labels = [NSMutableArray array];
    NSArray *known = @[ @[ @(SZFriendsRouteMethodLAN), @"lan" ], @[ @(SZFriendsRouteMethodPeerToPeerWiFi), @"p2p_wifi" ],
                        @[ @(SZFriendsRouteMethodBluetooth), @"bluetooth" ] ];
    for (NSArray *method in known) {
        if (![methods containsObject:method[0]]) continue;
        [names addObject:method[1]];
        [labels addObject:[s text:[@"found." stringByAppendingString:method[1]]]];
    }
    if (names.count == 0) return [NSNull null];
    NSString *label = labels[0];
    if (labels.count == 2) label = [s text:@"found.join" values:@{@"first" : labels[0], @"second" : labels[1]}];
    if (labels.count == 3) {
        label = [s text:@"found.join3" values:@{@"first" : labels[0], @"second" : labels[1], @"third" : labels[2]}];
    }
    return @{@"methods" : names, @"label" : label};
}

- (NSDictionary<NSString *, id> *)row:(NSDictionary<NSString *, id> *)row
                     foundWithMethods:(nullable NSArray<NSNumber *> *)methods {
    if (![self showsFound]) return row;
    NSMutableDictionary *found = [row mutableCopy];
    id value = [self foundWithMethods:methods];
    found[@"found"] = value;
    if (value != [NSNull null]) {
        NSString *spoken = [self.strings text:@"found.spoken" values:@{@"methods" : value[@"label"]}];
        found[@"accessibility_label"] = [@[ row[@"accessibility_label"], spoken ] componentsJoinedByString:@", "];
    }
    return found;
}

@end
