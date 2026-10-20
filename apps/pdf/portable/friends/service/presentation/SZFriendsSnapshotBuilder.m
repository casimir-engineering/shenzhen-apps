// Shenzhen Friends snapshot builder: shared pieces (avatars, routes, back arrows, the footer) and the badge and list
// views. Conversation, nearby, details, profile, settings and search live in the category files beside this one.
//
// Every value a view shows is decided here, so AppKit and GTK draw the same thing: rows sorted by latest
// interaction, the waiting count, which rows accept drops, and the spoken form of each row for VoiceOver and Orca.

#import "service/identity/SZFriendsIdentity.h"
#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder {
    SZFriendsStrings *_strings;
    SZFriendsAudience *_audience;
    SZFriendsAnimalSet *_animalSet;
    BOOL _animalSetChosen;
}

- (instancetype)initWithStrings:(SZFriendsStrings *)strings audience:(SZFriendsAudience *)audience {
    if ((self = [super init])) {
        _strings = strings;
        _audience = audience;
    }
    return self;
}

- (SZFriendsStrings *)strings {
    return _strings;
}

- (SZFriendsAudience *)audience {
    return _audience;
}

- (SZFriendsAnimalSet *)animalSet {
    if (!_animalSetChosen) {
        _animalSet = [SZFriendsAnimalSet bundledSet];
        _animalSetChosen = YES;
    }
    return _animalSet;
}

- (void)setAnimalSet:(SZFriendsAnimalSet *)animalSet {
    _animalSet = animalSet;
    _animalSetChosen = YES;
}

#pragma mark - People

- (NSString *)titleForPerson:(SZFriendsPersonFacts *)person {
    NSString *name = [person.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) return name;
    return person.friendsID.length ? [_strings displayID:person.friendsID] : [_strings text:@"person.unnamed"];
}

- (NSString *)initialsSourceForName:(NSString *)name friendsID:(NSString *)friendsID {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : friendsID ?: @"";
}

- (NSString *)firstNameForPerson:(SZFriendsPersonFacts *)person {
    return [_strings firstNameForName:person.name friendsID:person.friendsID];
}

- (NSDictionary<NSString *, id> *)avatarForPicture:(SZFriendsPicture *)picture
                                              seed:(NSString *)seed
                                       displayName:(NSString *)displayName {
    NSDictionary<NSString *, id> *fields = [picture protocolFieldsValidatedAgainst:self.animalSet];
    NSString *kind = [fields[@"kind"] isKindOfClass:NSString.class] ? fields[@"kind"] : @"placeholder";
    NSMutableDictionary<NSString *, id> *avatar = [NSMutableDictionary dictionary];
    avatar[@"kind"] = kind;
    // Only the keys PROTOCOL.md defines for this kind, whatever else the picture reports.
    if ([kind isEqualToString:@"animal"]) {
        avatar[@"set"] = fields[@"set"] ?: @(picture.animalSet);
        avatar[@"index"] = fields[@"index"] ?: @(picture.animalIndex);
    } else if ([kind isEqualToString:@"image"]) {
        avatar[@"path"] = fields[@"path"] ?: picture.imagePath ?: @"";
    }
    avatar[@"initials"] = SZFriendsInitials(displayName);
    // An animal's circle color comes from its manifest; everyone else gets a stable color for the person.
    BOOL animalColor = [kind isEqualToString:@"animal"] && [fields[@"color"] isKindOfClass:NSString.class];
    avatar[@"color"] = animalColor ? fields[@"color"] : SZFriendsPlaceholderColor(seed);
    return avatar;
}

- (NSDictionary<NSString *, id> *)avatarForPerson:(SZFriendsPersonFacts *)person {
    return [self avatarForPicture:person.picture seed:person.conversationID
                      displayName:[self initialsSourceForName:person.name friendsID:person.friendsID]];
}

static NSString *RouteKindName(SZFriendsRouteKind kind) {
    switch (kind) {
    case SZFriendsRouteKindLocal: return @"local";
    case SZFriendsRouteKindOnline: return @"online";
    case SZFriendsRouteKindOffline: return @"offline";
    case SZFriendsRouteKindNone: return @"none";
    }
    return @"none";
}

static id RouteMethodName(SZFriendsRouteMethod method) {
    switch (method) {
    case SZFriendsRouteMethodLAN: return @"lan";
    case SZFriendsRouteMethodPeerToPeerWiFi: return @"p2p_wifi";
    case SZFriendsRouteMethodBluetooth: return @"bluetooth";
    case SZFriendsRouteMethodInternet: return @"internet";
    case SZFriendsRouteMethodRelay: return @"relay";
    case SZFriendsRouteMethodNone: return [NSNull null];
    }
    return [NSNull null];
}

- (NSDictionary<NSString *, id> *)routeForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method {
    // A method only describes a working route; offline and none carry none.
    BOOL live = kind == SZFriendsRouteKindLocal || kind == SZFriendsRouteKindOnline;
    return @{
        @"kind" : RouteKindName(kind),
        @"method" : live ? RouteMethodName(method) : [NSNull null],
        @"label" : kind == SZFriendsRouteKindNone ? (id)[NSNull null] : [_strings routeLabelForKind:kind method:method]
    };
}

- (NSString *)spokenRouteForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method {
    if (kind == SZFriendsRouteKindNone) return nil;
    return [_strings spokenFragment:[_strings routeLabelForKind:kind method:method]];
}

- (BOOL)personWaits:(SZFriendsPersonFacts *)person {
    if (person.relation == SZFriendsPersonRelationBlocked || person.leftList) return NO;
    return person.relation == SZFriendsPersonRelationIncomingRequest || person.offersWaiting > 0 ||
           person.keyChangePending;
}

- (NSArray<SZFriendsPersonFacts *> *)peopleByLatestInteraction:(NSArray<SZFriendsPersonFacts *> *)people {
    return [people sortedArrayUsingComparator:^NSComparisonResult(SZFriendsPersonFacts *a, SZFriendsPersonFacts *b) {
      NSComparisonResult order = [b.lastInteractionAt compare:a.lastInteractionAt];
      // Ties fall back to the conversation id so two snapshots of the same facts never reorder rows.
      return order != NSOrderedSame ? order : [a.conversationID compare:b.conversationID];
    }];
}

- (BOOL)name:(NSString *)name friendsID:(NSString *)friendsID matchesQuery:(NSString *)query {
    NSString *needle = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (needle.length == 0) return YES;
    // An ID copied from text Friends showed carries U+2011 between its words; it still finds the ID.
    needle = [needle stringByReplacingOccurrencesOfString:@"\u2011" withString:@"-"];
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    if (name.length && [name rangeOfString:needle options:options].location != NSNotFound) return YES;
    if (!friendsID.length) return NO;
    // People type an ID the way they heard it: "cottage violet" finds cottage-violet.
    NSString *asID = [[needle componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
        componentsJoinedByString:@"-"];
    return [friendsID rangeOfString:needle options:options].location != NSNotFound ||
           [friendsID rangeOfString:asID options:options].location != NSNotFound;
}

#pragma mark - Shared view pieces

- (NSDictionary<NSString *, id> *)backToFriendsWithCount:(NSInteger)count thisRowWaits:(BOOL)thisRowWaits {
    NSString *label;
    if (count <= 0) label = [_strings text:@"back.friends"];
    else
        label = [_strings text:thisRowWaits ? @"back.friends.more_waiting" : @"back.friends.waiting"
                         count:count
                        values:nil];
    return @{
        @"badge_count" : @(MAX(count, 0)),
        @"badge_label" : [_strings badgeLabelForCount:count],
        @"accessibility_label" : label
    };
}

- (NSDictionary<NSString *, id> *)footerWithProfile:(SZFriendsProfileFacts *)profile {
    NSString *name = [profile.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return @{
        @"avatar" : [self avatarForPicture:profile.picture
                                      seed:profile.friendsID
                               displayName:name.length ? name : profile.friendsID],
        @"name" : name.length ? name : [NSNull null],
        @"name_placeholder" : [_strings text:@"footer.name_placeholder"],
        @"id_label" : [_strings text:@"id.label" values:@{@"id" : [_strings displayID:profile.friendsID]}],
        // Nothing while the ID is unreserved: the note raised a question it could not answer (the owner's report of
        // 2026-10-20). A changed ID is the list's banner; the field stays for views that read it.
        @"id_note" : [NSNull null],
        @"friends_id" : profile.friendsID,
        @"add_label" : [_strings text:@"footer.add"]
    };
}

- (NSMutableDictionary<NSString *, id> *)action:(NSString *)action label:(NSString *)label style:(NSString *)style {
    return [@{@"action" : action, @"label" : label, @"style" : style} mutableCopy];
}

- (NSDictionary<NSString *, id> *)confirmWithTitle:(NSString *)titleKey
                                              body:(NSString *)bodyKey
                                      confirmLabel:(NSString *)confirmKey
                                            values:(NSDictionary<NSString *, NSString *> *)values
                                       destructive:(BOOL)destructive {
    return @{
        @"title" : [_strings text:titleKey values:values],
        @"body" : [_strings text:bodyKey values:values],
        @"confirm_label" : [_strings text:confirmKey values:values],
        @"cancel_label" : [_strings text:@"static.cancel"],
        @"destructive" : SZFriendsBool(destructive)
    };
}

// How long Block's armed pill waits for the second click (brief § Interface): long enough to move the pointer back
// and click again, short enough that a pill left behind does not turn a later stray click into a block.
static const NSInteger SZFriendsBlockArmSeconds = 4;

- (NSDictionary<NSString *, id> *)blockArmNaming:(NSString *)who {
    return @{
        @"label" : [_strings text:@"list.action.block.armed"],
        @"accessibility_label" : [_strings text:@"list.action.block.armed_spoken" values:@{@"title" : who}],
        @"seconds" : @(SZFriendsBlockArmSeconds)
    };
}

- (NSMutableDictionary<NSString *, id> *)blockActionNaming:(NSString *)who label:(NSString *)label {
    NSMutableDictionary<NSString *, id> *block = [self action:@"block" label:label style:@"destructive"];
    block[@"arm"] = [self blockArmNaming:who];
    return block;
}

- (NSDictionary<NSString *, id> *)emptyWithKind:(NSString *)kind title:(NSString *)title body:(NSString *)body {
    NSMutableDictionary<NSString *, id> *empty = [@{@"title" : title, @"body" : body ?: [NSNull null]} mutableCopy];
    if (kind) empty[@"kind"] = kind;
    return empty;
}

#pragma mark - Badge

- (NSDictionary<NSString *, id> *)badgeWithPeople:(NSArray<SZFriendsPersonFacts *> *)people {
    NSInteger count = 0;
    for (SZFriendsPersonFacts *person in people) count += [self personWaits:person];
    return @{
        @"count" : @(count),
        @"label" : [_strings badgeLabelForCount:count],
        @"accessibility_label" : count ? [_strings text:@"badge.accessibility" count:count values:nil]
                                       : [_strings text:@"static.button_label"]
    };
}

#pragma mark - List

- (NSString *)waitingSubtitleForPerson:(SZFriendsPersonFacts *)person
                           previewItem:(SZFriendsItemFacts *)item
                                  kind:(NSString **)kind {
    if (person.relation == SZFriendsPersonRelationIncomingRequest) {
        *kind = @"request";
        if (person.unconfirmedAnswerID.length)
            return [_strings text:@"list.subtitle.answer"
                           values:@{@"id" : [_strings displayID:person.unconfirmedAnswerID]}];
        return [_strings text:@"list.subtitle.request"];
    }
    if (person.keyChangePending) {
        *kind = @"key_change";
        return [_strings text:@"list.subtitle.key_change" values:@{@"first" : [self firstNameForPerson:person]}];
    }
    *kind = @"offer";
    BOOL oneFile = person.offersWaiting == 1 && item.kind == SZFriendsItemFactsKindTransfer && !item.outgoing &&
                   item.fileName.length;
    if (oneFile) return [_strings text:@"list.subtitle.offer" values:@{@"file" : item.fileName}];
    return [_strings text:@"list.subtitle.offers" count:person.offersWaiting values:nil];
}

// The buttons a row carries itself: an incoming request is answered from the list without opening it. Block asks
// for a second click, so a slip of the pointer cannot block someone; Accept and Decline act at once, since Remove
// undoes an acceptance and a declined person may ask again. Accept and Decline say their word on the button, so a
// first-time reader tells Decline from Block; Block keeps its icon, red, and asks first.
- (NSArray<NSDictionary<NSString *, id> *> *)rowActionsForPerson:(SZFriendsPersonFacts *)person
                                                           title:(NSString *)title {
    if (person.relation != SZFriendsPersonRelationIncomingRequest) return @[];
    NSDictionary *who = @{@"title" : title};
    NSDictionary *arm = [self blockArmNaming:title];
    return @[
        @{@"action" : @"accept_request", @"icon" : @"accept", @"title" : [_strings text:@"action.accept"],
          @"label" : [_strings text:@"list.action.accept" values:who], @"arm" : [NSNull null]},
        @{@"action" : @"decline_request", @"icon" : @"decline", @"title" : [_strings text:@"action.decline"],
          @"label" : [_strings text:@"list.action.decline" values:who], @"arm" : [NSNull null]},
        @{@"action" : @"block", @"icon" : @"block", @"title" : [NSNull null],
          @"label" : [_strings text:@"list.action.block" values:who], @"arm" : arm},
    ];
}

// Remove, from the row's menu or a friend's details: what happens to this person, asked first. A friend is removed
// without being told, a request is declined or withdrawn, and anyone else only leaves the list; a blocked person stays
// blocked. With history, the person may also delete it there; otherwise the question says nothing about history.
- (NSDictionary<NSString *, id> *)removeConfirmForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = _strings;
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
                                         label:[_strings text:request ? @"action.cancel_request" : @"menu.remove"]
                                         style:@"destructive"];
    remove[@"note"] = [NSNull null];
    remove[@"arm"] = [NSNull null];
    remove[@"confirm"] = [self removeConfirmForPerson:person];
    return @[ remove ];
}

- (NSDictionary<NSString *, id> *)rowForPerson:(SZFriendsPersonFacts *)person
                                   previewItem:(SZFriendsItemFacts *)item
                                           now:(NSDate *)now {
    NSString *title = [self titleForPerson:person];
    NSString *subtitle, *spoken = nil, *waitingKind = nil;
    BOOL explainsRoute = NO;
    BOOL waits = [self personWaits:person];
    if (waits) {
        subtitle = [self waitingSubtitleForPerson:person previewItem:item kind:&waitingKind];
        spoken = [_strings spokenFragment:subtitle];
    } else if (person.relation == SZFriendsPersonRelationOutgoingRequest) {
        subtitle = [_strings text:@"list.subtitle.request_sent"];
    } else if (person.relation == SZFriendsPersonRelationBlocked) {
        subtitle = [_strings text:@"list.subtitle.blocked"];
    } else if (person.relation == SZFriendsPersonRelationRemoved && !person.linkContact) {
        subtitle = [_strings text:@"list.subtitle.removed"];
    } else {
        subtitle = [self previewForItem:item person:person spoken:&spoken explainsRoute:&explainsRoute];
    }
    if (!spoken) spoken = [_strings spokenFragment:subtitle];

    BOOL acceptsDrops = person.relation == SZFriendsPersonRelationFriend && !person.keyChangePending &&
                        [_audience.capabilities containsObject:@"drop.files"];
    NSMutableArray<NSString *> *said = [NSMutableArray arrayWithObject:title];
    if (person.unreadCount > 0) [said addObject:[_strings text:@"list.spoken.unread"]];
    if (spoken.length) [said addObject:spoken];
    [said addObject:[_strings timeAccessibilityLabelForDate:person.lastInteractionAt now:now]];
    NSString *route = [self spokenRouteForPerson:person];
    if (waits) [said addObject:[_strings text:@"list.spoken.waiting"]];
    else if (!explainsRoute && route.length) [said addObject:route];
    BOOL confirmed = person.friendsIDConfirmed && person.friendsID.length > 0;
    if (confirmed) [said addObject:[_strings text:@"list.spoken.id_confirmed"]];

    return @{
        @"conversation_id" : person.conversationID,
        @"avatar" : [self avatarForPerson:person],
        @"title" : title,
        @"subtitle" : subtitle,
        @"time_label" : [_strings timeLabelForDate:person.lastInteractionAt now:now],
        @"route" : [self routeForPerson:person],
        @"unread" : SZFriendsBool(person.unreadCount > 0),
        @"waiting" : waits ? @{@"kind" : waitingKind, @"label" : [_strings text:@"list.waiting"]} : [NSNull null],
        @"blocked" : SZFriendsBool(person.relation == SZFriendsPersonRelationBlocked),
        @"id_confirmed" : SZFriendsBool(confirmed),
        @"id_confirmed_label" : confirmed ? [_strings text:@"id.confirmed"] : [NSNull null],
        // The look is decided here, like every other display choice, so no view infers it from `blocked`.
        @"style" : person.relation == SZFriendsPersonRelationBlocked ? @"muted" : @"normal",
        @"drop_label" : acceptsDrops
                            ? [_strings text:@"list.drop" values:@{@"first" : [self firstNameForPerson:person]}]
                            : [NSNull null],
        @"drop_refusal" : acceptsDrops ? [NSNull null] : [self dropRefusalForPerson:person],
        @"accessibility_label" : [said componentsJoinedByString:@", "],
        @"actions" : [self rowActionsForPerson:person title:title]
    };
}

- (id)bannerForProfile:(SZFriendsProfileFacts *)profile {
    if (profile.identityState == SZFriendsIdentityFactsStateUnavailable) {
        NSMutableDictionary *reset = [self action:@"reset_friends" label:[_strings text:@"settings.reset.action"]
                                            style:@"destructive"];
        reset[@"confirm"] = [self confirmWithTitle:@"settings.reset.confirm.title"
                                              body:[self deletionBodyKey:@"settings.reset.confirm.body"]
                                      confirmLabel:@"settings.reset.confirm.button"
                                            values:nil
                                       destructive:YES];
        return @{@"kind" : @"identity_unavailable", @"text" : [_strings text:@"banner.identity_unavailable"],
                 @"action" : reset};
    }
    if (profile.updateNeed != SZFriendsUpdateNeedNone) {
        NSString *key =
            profile.updateNeed == SZFriendsUpdateNeedOnline ? @"banner.update_online" : @"banner.update_store";
        return @{@"kind" : @"update_required", @"text" : [_strings text:key values:@{@"app" : _audience.appName}],
                 @"action" : [NSNull null]};
    }
    if (profile.previousFriendsID.length) {
        return @{
            @"kind" : @"id_changed",
            @"text" : [_strings text:@"banner.id_changed"
                              values:@{@"id" : [_strings displayID:profile.friendsID],
                                       @"old" : [_strings displayID:profile.previousFriendsID]}],
            @"action" : [self action:@"dismiss_banner" label:[_strings text:@"banner.ok"] style:@"link"]
        };
    }
    return [NSNull null];
}

- (NSDictionary<NSString *, id> *)listWithPeople:(NSArray<SZFriendsPersonFacts *> *)people
                                    previewItems:(NSDictionary<NSString *, SZFriendsItemFacts *> *)previewItems
                                         profile:(SZFriendsProfileFacts *)profile
                                           query:(NSString *)query
                                             now:(NSDate *)now {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    // Previews resolve mentions against the very people and profile this list shows (PROTOCOL.md § Mentions).
    SZFriendsMentionDirectory *directory = self.mentionDirectory;
    self.mentionDirectory = [[SZFriendsMentionDirectory alloc] initWithPeople:people profile:profile];
    BOOL menus = [_audience.capabilities containsObject:@"list.menu"];
    NSUInteger listed = 0;
    for (SZFriendsPersonFacts *person in [self peopleByLatestInteraction:people]) {
        if (person.leftList) continue; // taken off the list; their conversation still opens from search
        listed++;
        if (![self name:person.name friendsID:person.friendsID matchesQuery:query]) continue;
        SZFriendsItemFacts *item = person.lastPreviewItemID ? previewItems[person.lastPreviewItemID] : nil;
        NSMutableDictionary *row = [[self rowForPerson:person previewItem:item now:now] mutableCopy];
        row[@"mentionable"] = [self mentionableForPerson:person]; // the @ picker's people, where a client has one
        if (menus) row[@"menu"] = [self rowMenuForPerson:person];
        [rows addObject:row];
    }
    self.mentionDirectory = directory;
    id empty = [NSNull null];
    if (rows.count == 0 && listed == 0) {
        empty = [self emptyWithKind:nil
                              title:[_strings text:@"list.empty.title"]
                               body:[_strings text:@"list.empty.body"]];
    } else if (rows.count == 0) {
        NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        empty = [self emptyWithKind:@"no_match"
                              title:[_strings text:@"search.no_match.title" values:@{@"query" : trimmed}]
                               body:[_strings text:@"search.no_match.body"]];
    }
    NSString *name = [profile.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    id prompt = name.length ? [NSNull null] : @{
        @"title" : [_strings text:@"name_prompt.title"],
        @"placeholder" : [_strings text:@"name.placeholder"],
        @"note" : [_strings text:@"name_prompt.note" values:@{@"id" : [_strings displayID:profile.friendsID]}]
    };
    return @{
        @"query" : query ?: @"",
        @"banner" : [self bannerForProfile:profile],
        @"name_prompt" : prompt,
        @"rows" : rows,
        @"empty" : empty,
        @"footer" : [self footerWithProfile:profile]
    };
}

#pragma mark - Views built in the category files

- (NSDictionary<NSString *, id> *)nearbyWithFacts:(SZFriendsNearbyFacts *)nearby
                                         profile:(SZFriendsProfileFacts *)profile
                                           query:(NSString *)query
                                             now:(NSDate *)now {
    return [self buildNearbyWithFacts:nearby profile:profile query:query now:now];
}

- (NSDate *)nearbyRefreshDateWithFacts:(SZFriendsNearbyFacts *)nearby now:(NSDate *)now {
    return [self searchingEndsWithFacts:nearby now:now];
}

- (NSDictionary<NSString *, id> *)conversationForPerson:(SZFriendsPersonFacts *)person
                                                  items:(NSArray<SZFriendsItemFacts *> *)items
                                             hasEarlier:(BOOL)hasEarlier
                                        highlightItemID:(NSString *)highlightItemID
                                       waitingElsewhere:(NSInteger)waitingElsewhere
                                                    now:(NSDate *)now {
    NSDictionary *conversation = [self buildConversationForPerson:person items:items hasEarlier:hasEarlier
                                                  highlightItemID:highlightItemID waitingElsewhere:waitingElsewhere
                                                              now:now];
    return [self conversationWithDevices:conversation person:person]; // You, a removed computer (+Devices)
}

- (NSDictionary<NSString *, id> *)detailsForPerson:(SZFriendsPersonFacts *)person
                                  waitingElsewhere:(NSInteger)waitingElsewhere
                                               now:(NSDate *)now {
    return [self buildDetailsForPerson:person waitingElsewhere:waitingElsewhere now:now];
}

- (NSDictionary<NSString *, id> *)profileWithFacts:(SZFriendsProfileFacts *)profile
                                  waitingElsewhere:(NSInteger)waitingElsewhere {
    NSMutableDictionary *data = [[self buildProfileWithFacts:profile waitingElsewhere:waitingElsewhere] mutableCopy];
    if (self.devices) data[@"devices"] = [self devicesSectionWithFacts:self.devices now:self.devices.now]; // +Devices
    return data;
}

- (NSDictionary<NSString *, id> *)nearbyAccessWithFacts:(SZFriendsNearbyFacts *)nearby
                                                profile:(SZFriendsProfileFacts *)profile {
    return [self buildNearbyAccessWithFacts:nearby profile:profile];
}

- (NSDictionary<NSString *, id> *)settingsWithProfile:(SZFriendsProfileFacts *)profile
                                               people:(NSArray<SZFriendsPersonFacts *> *)people {
    return [self buildSettingsWithProfile:profile people:people];
}

- (NSDictionary<NSString *, id> *)messageStatusWithMessages:(NSArray<SZFriendsItemFacts *> *)messages
                                                     people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people {
    return [self buildMessageStatusWithMessages:messages people:people];
}

- (NSDictionary<NSString *, id> *)searchResultWithHits:(NSArray<SZFriendsSearchHitFacts *> *)hits
                                                people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people
                                                  more:(BOOL)more
                                                   now:(NSDate *)now {
    return [self buildSearchResultWithHits:hits people:people more:more now:now];
}

@end
