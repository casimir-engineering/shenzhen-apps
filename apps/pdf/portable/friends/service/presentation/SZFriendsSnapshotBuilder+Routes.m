// Shenzhen Friends snapshot builder: how a friend shows connected, in list rows, the conversation header, details and
// the words about things still waiting to go (PROTOCOL.md § Shared objects, Route).
//
// The reader wants to know whether their message can reach the friend now. A live session answers it by its route
// ("Nearby, over Bluetooth", "Online, direct", "Online, through the Friends relay"); without one, a helper that reaches
// friends online also says whether it is trying ("Connecting to Mei…") or tried and failed ("Couldn’t connect just
// now").
// An M1 helper never says anything about online: its friends are reached nearby only, and the words say so.

#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsRoutes)

- (SZFriendsShownRoute)shownRouteForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsRouteMethod method = person.routeMethod;
    switch (person.routeKind) {
    case SZFriendsRouteKindLocal:
    case SZFriendsRouteKindOnline:
        // The nearby service reports every live session as its route; one over the Internet is not nearby.
        if (person.routeKind == SZFriendsRouteKindOnline || method == SZFriendsRouteMethodInternet ||
            method == SZFriendsRouteMethodRelay)
            return SZFriendsShownRouteOnline;
        return SZFriendsShownRouteLocal;
    case SZFriendsRouteKindNone:
        return SZFriendsShownRouteNone;
    case SZFriendsRouteKindOffline:
        break;
    }
    // Attempts reach friends only, and never one whose new key waits for review.
    if (!self.strings.reachesOnline || person.relation != SZFriendsPersonRelationFriend || person.keyChangePending)
        return SZFriendsShownRouteOffline;
    if (person.onlineReach == SZFriendsOnlineReachConnecting) return SZFriendsShownRouteConnecting;
    if (person.onlineReach == SZFriendsOnlineReachUnreachable) return SZFriendsShownRouteUnreachable;
    return SZFriendsShownRouteOffline;
}

- (NSString *)routeLabelForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    switch ([self shownRouteForPerson:person]) {
    case SZFriendsShownRouteNone:
        return nil;
    case SZFriendsShownRouteLocal:
        return [s routeLabelForKind:SZFriendsRouteKindLocal method:person.routeMethod];
    case SZFriendsShownRouteOnline:
        return [s routeLabelForKind:SZFriendsRouteKindOnline method:person.routeMethod];
    case SZFriendsShownRouteConnecting:
        return [s text:@"route.connecting" values:@{@"first" : [self firstNameForPerson:person]}];
    case SZFriendsShownRouteUnreachable:
        return [s text:@"route.unreachable"];
    case SZFriendsShownRouteOffline:
        // "Not nearby" would suggest nearby is the only way once friends are reached online too.
        return [s text:s.reachesOnline ? @"route.offline.online" : @"route.offline"];
    }
    return nil;
}

- (NSDictionary<NSString *, id> *)routeForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsShownRoute shown = [self shownRouteForPerson:person];
    if (shown == SZFriendsShownRouteLocal) return [self routeForKind:SZFriendsRouteKindLocal method:person.routeMethod];
    if (shown == SZFriendsShownRouteOnline)
        return [self routeForKind:SZFriendsRouteKindOnline method:person.routeMethod];
    if (shown == SZFriendsShownRouteNone) return [self routeForKind:SZFriendsRouteKindNone method:person.routeMethod];
    // Connecting draws the globe in the colour of a route that is not up yet; offline and unreachable the crossed dot.
    return @{
        @"kind" : shown == SZFriendsShownRouteConnecting ? @"connecting" : @"offline",
        @"method" : [NSNull null],
        @"label" : [self routeLabelForPerson:person]
    };
}

- (NSString *)spokenRouteForPerson:(SZFriendsPersonFacts *)person {
    NSString *label = [self routeLabelForPerson:person];
    if (!label.length) return nil;
    // "connecting to Mei" inside a longer sentence: the ellipsis would read as a pause in the middle of it.
    if ([label hasSuffix:@"…"]) label = [label substringToIndex:label.length - 1];
    return [self.strings spokenFragment:label];
}

- (NSString *)waitingKeyInFamily:(NSString *)family person:(SZFriendsPersonFacts *)person {
    NSString *suffix = @"queued";
    if ([self shownRouteForPerson:person] == SZFriendsShownRouteConnecting) suffix = @"connecting";
    else if (self.strings.reachesOnline) suffix = @"queued_online";
    return [NSString stringWithFormat:@"%@.%@", family, suffix];
}

- (NSString *)composerReachNoteForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSString *first = [self firstNameForPerson:person];
    switch ([self shownRouteForPerson:person]) {
    case SZFriendsShownRouteLocal:
    case SZFriendsShownRouteOnline:
    case SZFriendsShownRouteConnecting:
        return nil;
    case SZFriendsShownRouteUnreachable:
        return [s text:@"composer.note.unreachable" values:@{@"first" : first}];
    case SZFriendsShownRouteNone:
    case SZFriendsShownRouteOffline:
        break;
    }
    return [s text:s.reachesOnline ? @"static.queued_note.online" : @"static.queued_note"
            values:@{@"first" : first, @"apps" : [s text:@"apps.with_friends"]}];
}

@end
