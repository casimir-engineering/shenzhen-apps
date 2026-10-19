// Shenzhen Friends snapshot builder: the Nearby tab.
//
// Each discovery method reports its own state, and an unavailable one is never shown as an empty successful search
// (brief § Interface). When the method most people rely on, the local network, cannot work, one prominent card says
// so and how to fix it; when Bluetooth cannot work, one quiet line says who may be missed. Never both for one method,
// and nothing said twice: with a card up the empty state drops its body, and a spinner shows only beside people.

#import "service/presentation/SZFriendsPresentationPrivate.h"

static NSString *AdapterStateName(SZFriendsAdapterState state) {
    switch (state) {
    case SZFriendsAdapterStateNotAsked: return @"not_asked";
    case SZFriendsAdapterStateStarting: return @"starting";
    case SZFriendsAdapterStateWorking: return @"working";
    case SZFriendsAdapterStateDenied: return @"denied";
    case SZFriendsAdapterStateRadioOff: return @"radio_off";
    case SZFriendsAdapterStateUnavailable: return @"unavailable";
    }
    return @"unavailable";
}

static BOOL Broken(SZFriendsAdapterState state) {
    return state == SZFriendsAdapterStateDenied || state == SZFriendsAdapterStateRadioOff ||
           state == SZFriendsAdapterStateUnavailable;
}

static id RFC3339(NSDate *date) {
    if (!date) return [NSNull null];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [formatter stringFromDate:date];
}

@implementation SZFriendsSnapshotBuilder (SZFriendsNearby)

- (NSDate *)searchingEndsWithFacts:(SZFriendsNearbyFacts *)nearby now:(NSDate *)now {
    BOOL working = nearby.networkState == SZFriendsAdapterStateWorking ||
                   nearby.bluetoothState == SZFriendsAdapterStateWorking;
    if (!working || !nearby.workingSince) return nil;
    NSDate *end = [nearby.workingSince dateByAddingTimeInterval:SZFriendsNearbySearchingSeconds];
    return [end compare:now] == NSOrderedDescending ? end : nil;
}

- (NSDictionary *)emptyForNearby:(SZFriendsNearbyFacts *)nearby
                        filtered:(BOOL)filtered
                           query:(NSString *)query
                           alert:(BOOL)alert
                             now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    if (filtered)
        return [self emptyWithKind:@"no_match" title:[s text:@"search.no_match.title" values:@{@"query" : query}]
                              body:[s text:@"search.no_match.body"]];
    BOOL starting = nearby.networkState == SZFriendsAdapterStateStarting ||
                    nearby.bluetoothState == SZFriendsAdapterStateStarting ||
                    nearby.networkState == SZFriendsAdapterStateNotAsked ||
                    nearby.bluetoothState == SZFriendsAdapterStateNotAsked;
    BOOL working = nearby.networkState == SZFriendsAdapterStateWorking ||
                   nearby.bluetoothState == SZFriendsAdapterStateWorking;
    if (!working && !starting) {
        // A card above already says what to turn on or allow, so the empty state only says that Nearby is down.
        NSString *body = nil;
        if (!alert) {
            BOOL radio = nearby.networkState == SZFriendsAdapterStateRadioOff ||
                         nearby.bluetoothState == SZFriendsAdapterStateRadioOff;
            body = [s text:radio ? @"nearby.empty.unavailable.body.radio" : @"nearby.empty.unavailable.body.access"
                    values:@{@"app" : self.audience.appName}];
        }
        return [self emptyWithKind:@"unavailable" title:[s text:@"nearby.empty.unavailable.title"] body:body];
    }
    // "Nobody" a second after starting is a guess; the first results take a few seconds on any method.
    if (!working || [self searchingEndsWithFacts:nearby now:now])
        return [self emptyWithKind:@"searching" title:[s text:@"nearby.empty.searching.title"] body:nil];
    // Under a card, the note line already says Bluetooth is still looking.
    NSString *body = alert ? nil : [s text:@"nearby.empty.nobody.body" values:@{@"app" : self.audience.appName}];
    return [self emptyWithKind:@"nobody" title:[s text:@"nearby.empty.nobody.title"] body:body];
}

- (NSDictionary *)visibilityWithFacts:(SZFriendsNearbyFacts *)nearby now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSDictionary *app = @{@"app" : self.audience.appName};
    NSTimeInterval remaining = nearby.visibilityDeadline ? [nearby.visibilityDeadline timeIntervalSinceDate:now] : 0;
    BOOL canAdvertise = !Broken(nearby.networkState) || !Broken(nearby.bluetoothState);
    if (remaining > 0 && canAdvertise) {
        return @{
            @"state" : @"visible",
            @"title" : [s text:@"visibility.visible.title"],
            @"body" : [s text:@"visibility.visible.body"],
            @"remaining_label" : [s countdownLabelForRemaining:remaining],
            @"remaining_accessibility_label" : [s countdownAccessibilityLabelForRemaining:remaining],
            @"deadline" : RFC3339(nearby.visibilityDeadline),
            @"action" : [self action:@"stop_visibility" label:[s text:@"visibility.stop"] style:@"secondary"]
        };
    }
    if (!canAdvertise) {
        BOOL radio = nearby.networkState == SZFriendsAdapterStateRadioOff ||
                     nearby.bluetoothState == SZFriendsAdapterStateRadioOff;
        return @{
            @"state" : @"unavailable",
            @"title" : [NSNull null],
            @"body" : [s text:radio ? @"visibility.unavailable.radio" : @"visibility.unavailable.access" values:app],
            @"remaining_label" : [NSNull null],
            @"remaining_accessibility_label" : [NSNull null],
            @"deadline" : [NSNull null],
            @"action" : [NSNull null]
        };
    }
    return @{
        @"state" : @"hidden",
        @"title" : [NSNull null],
        @"body" : [s text:@"visibility.hidden.body"],
        @"remaining_label" : [NSNull null],
        @"remaining_accessibility_label" : [NSNull null],
        @"deadline" : [NSNull null],
        @"action" : [self action:@"start_visibility" label:[s text:@"visibility.start"] style:@"primary"]
    };
}

- (NSDictionary *)settingsAction:(NSString *)target labelKey:(NSString *)labelKey style:(NSString *)style {
    NSMutableDictionary *action = [self action:@"open_settings" label:[self.strings text:labelKey] style:style];
    action[@"settings_target"] = target;
    return action;
}

- (id)alertWithFacts:(SZFriendsNearbyFacts *)nearby {
    SZFriendsStrings *s = self.strings;
    NSDictionary *app = @{@"app" : self.audience.appName};
    switch (nearby.networkState) {
    case SZFriendsAdapterStateDenied:
        return @{
            @"title" : [s text:@"alert.network_denied.title" values:app],
            @"body" : [s text:@"alert.network_denied.body" values:app],
            @"action" : [self settingsAction:@"local_network_privacy"
                                    labelKey:@"settings_link.privacy"
                                       style:@"secondary"]
        };
    case SZFriendsAdapterStateRadioOff: {
        // Both radios off: the card names both, because the quiet Bluetooth line never shows under a card about the
        // same remedy, and "Wi-Fi is off" alone would leave Bluetooth's state unsaid.
        BOOL both = nearby.bluetoothState == SZFriendsAdapterStateRadioOff;
        return @{
            @"title" : [s text:both ? @"alert.radios_off.title" : @"alert.wifi_off.title"],
            @"body" : [s text:both ? @"alert.radios_off.body" : @"alert.wifi_off.body"],
            @"action" : [self settingsAction:@"wifi" labelKey:@"settings_link.wifi" style:@"secondary"]
        };
    }
    case SZFriendsAdapterStateUnavailable:
        return @{
            @"title" : [s text:@"alert.network_unavailable.title" values:app],
            @"body" : [s text:@"alert.network_unavailable.body"],
            @"action" : [NSNull null]
        };
    default: return [NSNull null];
    }
}

- (id)noteWithFacts:(SZFriendsNearbyFacts *)nearby alert:(BOOL)alert {
    SZFriendsStrings *s = self.strings;
    NSDictionary *app = @{@"app" : self.audience.appName};
    if (alert) {
        // The card explains the network. The line says who is still found, or what is wrong with Bluetooth too,
        // unless the card already named both radios.
        if (nearby.bluetoothState == SZFriendsAdapterStateWorking)
            return @{@"text" : [s text:@"note.still_bluetooth"], @"action" : [NSNull null]};
        BOOL bothRadiosOff = nearby.networkState == SZFriendsAdapterStateRadioOff &&
                             nearby.bluetoothState == SZFriendsAdapterStateRadioOff;
        if (bothRadiosOff) return [NSNull null];
    } else if (Broken(nearby.networkState)) {
        return [NSNull null];
    }
    // Under a card nobody appears at all, so "people nearby without Wi-Fi won't appear" would suggest others still
    // do; the line then only adds Bluetooth's state to the card's.
    NSString *suffix = alert ? @".under_card" : @"";
    switch (nearby.bluetoothState) {
    case SZFriendsAdapterStateRadioOff:
        return @{
            @"text" : [s text:[@"note.bluetooth_off" stringByAppendingString:suffix]],
            @"action" : [self settingsAction:@"bluetooth" labelKey:@"settings_link.bluetooth" style:@"link"]
        };
    case SZFriendsAdapterStateDenied:
        return @{
            @"text" : [s text:[@"note.bluetooth_denied" stringByAppendingString:suffix] values:app],
            @"action" : [self settingsAction:@"bluetooth_privacy" labelKey:@"settings_link.privacy" style:@"link"]
        };
    case SZFriendsAdapterStateUnavailable:
        return @{@"text" : [s text:[@"note.bluetooth_unavailable" stringByAppendingString:suffix]],
                 @"action" : [NSNull null]};
    default: return [NSNull null];
    }
}

- (NSDictionary *)personEntry:(SZFriendsNearbyPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSString *name = [person.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *title = name.length                ? name
                      : person.friendsID.length ? [s displayID:person.friendsID]
                                                : [s text:@"person.unnamed"];
    BOOL friend = !person.isStranger && person.relation == SZFriendsPersonRelationFriend;
    NSString *subtitle, *status = nil, *spoken;
    id action = [NSNull null];
    if (friend) {
        NSString *key = person.routeMethod == SZFriendsRouteMethodBluetooth   ? @"nearby.subtitle.bluetooth"
                        : person.routeMethod == SZFriendsRouteMethodPeerToPeerWiFi ? @"nearby.subtitle.p2p_wifi"
                                                                                  : @"nearby.subtitle.lan";
        subtitle = [s text:key];
        status = [s text:@"nearby.status.friend"];
        spoken = [@[ title, [s spokenFragment:status],
                     [[s spokenFragment:subtitle] stringByReplacingOccurrencesOfString:@" · " withString:@", "] ]
            componentsJoinedByString:@", "];
    } else {
        subtitle = [s text:name.length ? @"nearby.subtitle.visible" : @"nearby.subtitle.no_name"];
        if (person.relation == SZFriendsPersonRelationOutgoingRequest) status = [s text:@"nearby.status.request_sent"];
        else if (person.relation == SZFriendsPersonRelationIncomingRequest) status = [s text:@"list.subtitle.request"];
        else if (person.nearbyID.length)
            action = [self action:@"send_request" label:[s text:@"nearby.request"] style:@"primary"];
        // The status says more than "visible now" once there is one.
        spoken = [@[ title, [s spokenFragment:status ?: subtitle] ] componentsJoinedByString:@", "];
    }
    NSString *seed = person.conversationID ?: person.nearbyID ?: title;
    return @{
        @"nearby_id" : person.nearbyID ?: [NSNull null],
        @"conversation_id" : person.conversationID ?: [NSNull null],
        @"avatar" : [self avatarForPicture:person.picture seed:seed
                               displayName:[self initialsSourceForName:person.name friendsID:person.friendsID]],
        @"title" : title,
        @"subtitle" : subtitle,
        @"status_label" : status ?: [NSNull null],
        @"action" : action,
        @"accessibility_label" : spoken
    };
}

- (NSDictionary<NSString *, id> *)buildNearbyWithFacts:(SZFriendsNearbyFacts *)nearby
                                         profile:(SZFriendsProfileFacts *)profile
                                           query:(NSString *)query
                                             now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSDictionary *app = @{@"app" : self.audience.appName};
    id alert = [self alertWithFacts:nearby];
    BOOL hasAlert = alert != [NSNull null];
    NSMutableArray *friends = [NSMutableArray array], *others = [NSMutableArray array];
    NSUInteger visible = 0;
    for (SZFriendsNearbyPersonFacts *person in nearby.people) {
        if (person.relation == SZFriendsPersonRelationBlocked) continue; // blocked people never appear
        visible++;
        if (![self name:person.name friendsID:person.friendsID matchesQuery:query]) continue;
        BOOL friend = !person.isStranger && person.relation == SZFriendsPersonRelationFriend;
        // Friends first; everyone else in the order the methods reported them, so rows do not jump around.
        [friend ? friends : others addObject:[self personEntry:person]];
    }
    NSArray *people = [friends arrayByAddingObjectsFromArray:others];
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    id empty = people.count ? [NSNull null]
                            : [self emptyForNearby:nearby filtered:visible > 0 && trimmed.length
                                             query:trimmed alert:hasAlert now:now];
    return @{
        @"query" : query ?: @"",
        @"visibility" : [self visibilityWithFacts:nearby now:now],
        @"methods" : @[
            @{@"method" : @"network", @"state" : AdapterStateName(nearby.networkState),
              @"label" : [s text:[@"method.network." stringByAppendingString:AdapterStateName(nearby.networkState)]
                          values:app]},
            @{@"method" : @"bluetooth", @"state" : AdapterStateName(nearby.bluetoothState),
              @"label" : [s text:[@"method.bluetooth." stringByAppendingString:AdapterStateName(nearby.bluetoothState)]
                          values:app]}
        ],
        @"alert" : alert,
        @"note" : [self noteWithFacts:nearby alert:hasAlert],
        // Only beside people: an empty list already says whether it is looking. With the card up, the note line
        // already says what is still being searched.
        @"status" : nearby.searching && !hasAlert && people.count
                        ? @{@"kind" : @"searching", @"label" : [s text:@"nearby.still_looking"]}
                        : [NSNull null],
        @"people" : people,
        @"empty" : empty,
        @"footer" : [self footerWithProfile:profile]
    };
}

@end
