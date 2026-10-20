// Shenzhen Friends snapshot builder: the conversation view (header, back arrow, items, request card, composer).
//
// A pending request replaces history and composer with the request card, whose comparison code both screens show
// so the two people can check they reached each other (ADR 0001, commit-then-reveal). The composer says when
// queued messages will go, from the reader's side: "Messages and files send when Priya is nearby with
// ShenzhenPDF, Shenzhen Files or Shenzhen 3D open." It names every app that runs Friends (apps.with_friends), not
// the reading app, because any of them open on each computer is enough.

#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsConversation)

- (BOOL)isRequest:(SZFriendsPersonFacts *)person {
    return person.relation == SZFriendsPersonRelationIncomingRequest ||
           person.relation == SZFriendsPersonRelationOutgoingRequest;
}

- (NSDictionary *)headerForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSString *title = [self titleForPerson:person];
    BOOL details = ![self isRequest:person];
    BOOL blocked = person.relation == SZFriendsPersonRelationBlocked;
    NSString *subtitle = blocked ? [s text:@"list.subtitle.blocked"] : [self routeLabelForPerson:person];
    // The line is said as well as shown, whatever it says ("Nearby, over Bluetooth", "Blocked").
    NSString *said = blocked ? [s spokenFragment:subtitle] : [self spokenRouteForPerson:person];
    NSDictionary *values = @{@"title" : title, @"route" : said ?: @""};
    NSString *spoken = title;
    if (details) spoken = [s text:subtitle ? @"header.spoken.route_details" : @"header.spoken.details" values:values];
    else if (subtitle) spoken = [s text:@"header.spoken.route" values:values];
    // A blocked friend's line says "Blocked", not how they are connected, so it carries no route icon or tooltip.
    return @{
        @"title" : title,
        @"subtitle" : subtitle ?: [NSNull null],
        @"route" : blocked ? [self routeForKind:SZFriendsRouteKindNone method:SZFriendsRouteMethodNone]
                           : [self routeForPerson:person],
        @"avatar" : [self avatarForPerson:person],
        @"details_available" : SZFriendsBool(details),
        @"accessibility_label" : spoken
    };
}

- (id)requestCardForPerson:(SZFriendsPersonFacts *)person now:(NSDate *)now {
    if (![self isRequest:person]) return [NSNull null];
    SZFriendsStrings *s = self.strings;
    BOOL incoming = person.relation == SZFriendsPersonRelationIncomingRequest;
    // An unconfirmed answer to our own Add by ID waits like a request, and says what we asked for and why it waits.
    BOOL answer = incoming && person.unconfirmedAnswerID.length > 0;
    NSDictionary *values = @{@"title" : [self titleForPerson:person], @"first" : [self firstNameForPerson:person],
                             @"id" : [s displayID:person.unconfirmedAnswerID]};
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (answer)
        [parts addObject:[s text:@"request.asked_for" values:values]];
    else if (incoming)
        [parts addObject:[s text:person.requestFoundNearby ? @"request.found_nearby" : @"request.by_id"]];
    else
        [parts addObject:[s text:@"request.sent"]];
    if (person.requestAt) [parts addObject:[s momentPhraseForDate:person.requestAt now:now]];
    if (person.friendsID.length)
        [parts addObject:[s text:@"id.label" values:@{@"id" : [s displayID:person.friendsID]}]];
    NSString *subtitle = [parts componentsJoinedByString:@" · "];
    if (!incoming && parts.count > 1) {
        // "Request sent · today at 14:40" reads better as "Sent today at 14:40" after the card's title.
        subtitle = [[s text:@"request.sent_at" values:@{@"moment" : parts[1]}]
            stringByAppendingString:parts.count > 2 ? [@" · " stringByAppendingString:parts[2]] : @""];
    }

    NSString *code = person.comparisonCode.length == 6 ? person.comparisonCode : nil;
    NSMutableArray *actions = [NSMutableArray array];
    if (incoming) {
        [actions addObject:[self action:@"accept_request" label:[s text:@"action.accept"] style:@"primary"]];
        [actions addObject:[self action:@"decline_request" label:[s text:@"action.decline"] style:@"secondary"]];
        // Destructive and armed like the list row's Block, never a link beside Accept and Decline.
        NSString *first = [self firstNameForPerson:person];
        [actions addObject:[self blockActionNaming:first label:[s text:@"action.block" values:values]]];
    } else {
        [actions addObject:[self action:@"cancel_request" label:[s text:@"action.cancel_request"] style:@"secondary"]];
    }
    NSString *promptKey = code ? (incoming ? @"request.code_prompt.incoming" : @"request.code_prompt.outgoing")
                               : @"request.code_later";
    NSString *titleKey = answer ? @"request.title.answer" : incoming ? @"request.title.incoming"
                                                                     : @"request.title.outgoing";
    NSString *footnoteKey = answer ? @"request.footnote.answer" : incoming ? @"request.footnote.incoming"
                                                                           : @"request.footnote.outgoing";
    return @{
        @"direction" : incoming ? @"incoming" : @"outgoing",
        @"avatar" : [self avatarForPerson:person],
        @"title" : [s text:titleKey values:values],
        @"subtitle" : subtitle,
        @"code_prompt" : [s text:promptKey values:values],
        @"comparison_code" : code ? [s groupedComparisonCode:code] : [NSNull null],
        @"comparison_code_accessibility_label" : code ? [s spokenComparisonCode:code] : [NSNull null],
        @"actions" : actions,
        @"footnote" : [s text:footnoteKey values:values]
    };
}

// "Type # to attach, @ to mention someone, or drop files here": the keys the host offers, emphasised, each with what
// it does, then dropping files; "Drop files here to send them" when dropping is all there is.
- (NSArray *)composerHint {
    SZFriendsStrings *s = self.strings;
    NSSet<NSString *> *capabilities = self.audience.capabilities;
    NSMutableArray<NSArray<NSString *> *> *keyed = [NSMutableArray array];
    if ([capabilities containsObject:@"attach.items"]) [keyed addObject:@[ @"#", [s text:@"composer.hint.attach"] ]];
    if ([capabilities containsObject:@"mentions"]) [keyed addObject:@[ @"@", [s text:@"composer.hint.mention"] ]];
    if ([capabilities containsObject:@"assistant.drafts"])
        [keyed addObject:@[ @"/", [s text:@"composer.hint.assistant"] ]];
    BOOL drop = [capabilities containsObject:@"drop.files"];
    if (!keyed.count) return drop ? @[ @{@"text" : [s text:@"composer.hint.drop_alone"]} ] : @[];
    NSUInteger items = keyed.count + (drop ? 1 : 0);
    NSString *orWord = [s text:@"composer.hint.or"];
    // Before the last of two: " or "; of three or more: ", or "; between the others: ", ".
    NSString *(^separator)(NSUInteger) = ^NSString *(NSUInteger index) {
        if (index + 1 < items) return @", ";
        return items == 2 && !drop ? [NSString stringWithFormat:@" %@ ", orWord]
                                   : [NSString stringWithFormat:@", %@ ", orWord];
    };
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSMutableString *plain = [NSMutableString stringWithFormat:@"%@ ", [s text:@"composer.hint.type"]];
    for (NSUInteger i = 0; i < keyed.count; i++) {
        if (i > 0) [plain appendString:separator(i)];
        [segments addObject:@{@"text" : [plain copy]}];
        [segments addObject:@{@"text" : keyed[i][0], @"emphasis" : @YES}];
        [plain setString:[@" " stringByAppendingString:keyed[i][1]]];
    }
    if (drop) [plain appendFormat:@"%@%@", separator(keyed.count), [s text:@"composer.hint.drop"]];
    [segments addObject:@{@"text" : [plain copy]}];
    return segments;
}

- (NSDictionary *)composerForPerson:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSDictionary *values = @{@"first" : [self firstNameForPerson:person]};
    BOOL request = [self isRequest:person];
    BOOL friend = person.relation == SZFriendsPersonRelationFriend;
    BOOL enabled = friend && !person.keyChangePending;
    NSString *note = nil;
    if (person.relation == SZFriendsPersonRelationBlocked) note = [s text:@"composer.note.blocked" values:values];
    else if (person.relation == SZFriendsPersonRelationRemoved) {
        note = [s text:person.linkContact ? @"composer.note.link_contact" : @"composer.note.removed" values:values];
    }
    else if (person.keyChangePending) note = [s text:@"composer.note.key_change" values:values];
    else if (friend) note = [self composerReachNoteForPerson:person];
    NSMutableDictionary *composer = [@{
        @"visible" : SZFriendsBool(!request),
        @"enabled" : SZFriendsBool(enabled),
        @"placeholder" : [s text:@"composer.placeholder" values:values],
        @"hint" : request ? @[] : [self composerHint],
        @"send_label" : [s text:@"composer.send"],
        @"note" : note ?: [NSNull null],
        @"accepts_drops" : SZFriendsBool(enabled && [self.audience.capabilities containsObject:@"drop.files"]),
        @"max_text_bytes" : @32768 // PROTOCOL.md § Limits: one session frame (ADR 0001)
    } mutableCopy];
    // The @ picker's footer, for clients that show mentions (PROTOCOL.md § Mentions).
    composer[@"mention_note"] = [self mentionNoteForPerson:person enabled:enabled];
    return composer;
}

- (NSDictionary<NSString *, id> *)buildConversationForPerson:(SZFriendsPersonFacts *)person
                                                  items:(NSArray<SZFriendsItemFacts *> *)items
                                             hasEarlier:(BOOL)hasEarlier
                                        highlightItemID:(NSString *)highlightItemID
                                       waitingElsewhere:(NSInteger)waitingElsewhere
                                                    now:(NSDate *)now {
    BOOL request = [self isRequest:person];
    NSArray *rendered = request ? @[]
                                : [self itemsForPerson:person items:items highlightItemID:highlightItemID now:now];
    BOOL highlightShown = NO;
    for (NSDictionary *item in rendered) highlightShown = highlightShown || [item[@"highlighted"] boolValue];
    return @{
        @"conversation_id" : person.conversationID,
        @"header" : [self headerForPerson:person],
        @"back" : [self backToFriendsWithCount:waitingElsewhere thisRowWaits:[self personWaits:person]],
        @"search_placeholder" : [self.strings text:@"static.conversation_search_placeholder"],
        @"has_earlier" : SZFriendsBool(hasEarlier && !request),
        @"items" : rendered,
        @"highlight_item_id" : highlightShown ? highlightItemID : [NSNull null],
        @"request" : [self requestCardForPerson:person now:now],
        @"composer" : [self composerForPerson:person]
    };
}

@end
