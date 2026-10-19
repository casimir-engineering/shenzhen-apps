// Shenzhen Friends snapshot builder: mentions as the reader sees them (PROTOCOL.md § Mentions, ADR 0007).
//
// A message carries each mention as a link holding the person's Friends ID, identity key and the name the sender
// sees. Whoever reads it sees it resolved against their own Friends list: a friend (matched by key) under the reader's
// own name for them, which opens their chat; the reader themselves, highlighted; anyone else under the sender's name,
// never the ID, with a card to add them; and a forged mention (a friend's or the reader's own ID under another key) as
// plain text. The ID and key never reach a view except on that card, which needs them to send add_from_mention.

#import "service/presentation/SZFriendsMentions.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsResolvedText
@end

@implementation SZFriendsMentionDirectory {
    NSDictionary<NSData *, SZFriendsPersonFacts *> *_byKey;
    NSDictionary<NSString *, NSArray<SZFriendsPersonFacts *> *> *_byID;
}

- (instancetype)initWithPeople:(NSArray<SZFriendsPersonFacts *> *)people profile:(SZFriendsProfileFacts *)profile {
    if ((self = [super init])) {
        _profile = profile;
        NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableArray *> *byID = [NSMutableDictionary dictionary];
        for (SZFriendsPersonFacts *person in people) {
            if (person.identityKey.length == 32) byKey[person.identityKey] = person;
            if (!person.friendsID.length) continue;
            if (!byID[person.friendsID]) byID[person.friendsID] = [NSMutableArray array];
            [byID[person.friendsID] addObject:person];
        }
        _byKey = byKey;
        _byID = byID;
    }
    return self;
}

- (SZFriendsPersonFacts *)personWithIdentityKey:(NSData *)identityKey {
    return _byKey[identityKey];
}

- (NSArray<SZFriendsPersonFacts *> *)peopleWithFriendsID:(NSString *)friendsID {
    return _byID[friendsID] ?: @[];
}

@end

@implementation SZFriendsStrings (SZFriendsMentions)

- (NSString *)addFromMentionSentMessageForName:(NSString *)name {
    // Before this Mac reaches friends online the request travels nearby only, as add_by_id's reply says.
    return [self text:@"add_from_mention.sent" values:@{@"name" : name}];
}

- (NSString *)addFromMentionSentMessageForName:(NSString *)name online:(BOOL)online {
    return [self text:online ? @"add_from_mention.sent.online" : @"add_from_mention.sent" values:@{@"name" : name}];
}

@end

@implementation SZFriendsSnapshotBuilder (SZFriendsMentions)

#pragma mark - Resolving one mention

- (NSDictionary *)mentionWithURL:(NSString *)url
                            kind:(NSString *)kind
                           label:(NSString *)label
                         tooltip:(nullable NSString *)tooltip
                  conversationID:(nullable NSString *)conversationID
                            card:(nullable NSDictionary *)card {
    return @{
        @"url" : url,
        @"kind" : kind,
        @"label" : [@"@" stringByAppendingString:label],
        @"tooltip" : tooltip ?: [NSNull null],
        @"conversation_id" : conversationID ?: [NSNull null],
        @"card" : card ?: [NSNull null]
    };
}

// Someone the reader is not friends with: the sender's name, a card with the ID, and what the reader can do about
// them from here, which depends on what is already between them.
- (NSDictionary *)strangerMention:(SZFriendsTextLink *)link
                           person:(nullable SZFriendsPersonFacts *)person
                        directory:(SZFriendsMentionDirectory *)directory
                              url:(NSString *)url {
    SZFriendsStrings *s = self.strings;
    NSString *name = link.name;
    NSDictionary *values = @{@"name" : name, @"id" : [s displayID:link.friendsID],
                             @"first" : [s firstNameForName:name friendsID:nil]};
    // The host vouched that this ID now belongs to another key: Add would reach someone else, so it is not offered.
    BOOL moved = NO;
    for (SZFriendsPersonFacts *holder in [directory peopleWithFriendsID:link.friendsID])
        moved = moved || (holder.friendsIDConfirmed && ![holder.identityKey isEqualToData:link.identityKey]);
    NSMutableArray *actions = [NSMutableArray array];
    NSString *state = @"stranger", *status = nil;
    // Nobody known by this key reads as removed: nothing between them, so Add. (A nil person's relation would read
    // as 0, an incoming request.)
    SZFriendsPersonRelation relation = person ? person.relation : SZFriendsPersonRelationRemoved;
    if (relation == SZFriendsPersonRelationBlocked) {
        state = @"blocked";
    } else if (moved) {
        state = @"moved";
    } else if (relation == SZFriendsPersonRelationOutgoingRequest) {
        state = @"requested";
    } else if (relation == SZFriendsPersonRelationIncomingRequest) {
        state = @"asked";
        [actions addObject:[self action:@"accept_request" label:[s text:@"action.accept"] style:@"primary"]];
        [actions addObject:[self action:@"decline_request" label:[s text:@"action.decline"] style:@"secondary"]];
        [actions addObject:[self blockActionNaming:name label:[s text:@"action.block" values:values]]];
    } else {
        NSMutableDictionary *add = [self action:@"add_from_mention" label:[s text:@"mention.action.add"]
                                          style:@"primary"];
        add[@"friends_id"] = link.friendsID;
        add[@"identity_key"] = SZFriendsMentionKeyString(link.identityKey);
        add[@"name"] = name;
        [actions addObject:add];
    }
    if (![state isEqualToString:@"stranger"])
        status = [s text:[@"mention.card." stringByAppendingString:state] values:values];
    NSDictionary *card = @{
        @"title" : name,
        @"id_label" : [s text:@"mention.card.id" values:values],
        @"status_label" : status ?: [NSNull null],
        @"conversation_id" : person.conversationID ?: [NSNull null],
        @"actions" : actions
    };
    NSString *tooltip = [s text:[@"mention.tooltip." stringByAppendingString:state] values:values];
    return [self mentionWithURL:url kind:@"stranger" label:name tooltip:tooltip conversationID:nil card:card];
}

// The protocol's mention object for a well-formed link, or nil when it shows as plain text: no directory to resolve
// against, or a forged mention.
- (nullable NSDictionary *)mentionForLink:(SZFriendsTextLink *)link url:(NSString *)url {
    SZFriendsMentionDirectory *directory = self.mentionDirectory;
    if (!directory || !link.isMention) return nil;
    SZFriendsProfileFacts *profile = directory.profile;
    if ([profile.identityPublicKey isEqualToData:link.identityKey]) {
        NSString *own = [profile.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return [self mentionWithURL:url kind:@"you" label:own.length ? own : [self.strings displayID:profile.friendsID]
                            tooltip:nil conversationID:nil card:nil];
    }
    SZFriendsPersonFacts *person = [directory personWithIdentityKey:link.identityKey];
    if (person.relation == SZFriendsPersonRelationFriend) {
        NSString *tooltip = [self.strings text:@"mention.tooltip.friend"
                                        values:@{@"first" : [self firstNameForPerson:person]}];
        return [self mentionWithURL:url kind:@"friend" label:[self titleForPerson:person] tooltip:tooltip
                     conversationID:person.conversationID card:nil];
    }
    // Forged: the reader's own ID, or a friend's, under a key that is not theirs.
    if ([profile.friendsID isEqualToString:link.friendsID]) return nil;
    for (SZFriendsPersonFacts *other in [directory peopleWithFriendsID:link.friendsID]) {
        if (other.relation == SZFriendsPersonRelationFriend) return nil;
    }
    return [self strangerMention:link person:person directory:directory url:url];
}

#pragma mark - Whole texts

// Each link's mention object, or NSNull where it shows as plain text. Links count toward `url`s only once resolved,
// so the n-th link a view can click is always "szfriends:mention?ref=n", whatever plain text sits between.
- (NSArray *)mentionsForLinks:(NSArray<SZFriendsTextLink *> *)links {
    NSMutableArray *mentions = [NSMutableArray arrayWithCapacity:links.count];
    NSUInteger seen = 0, linked = 0;
    for (SZFriendsTextLink *link in links) {
        NSString *url = [NSString stringWithFormat:@"szfriends:mention?ref=%lu", (unsigned long)linked];
        // Beyond the twentieth a mention is plain text, as the receiving helper already made it.
        NSDictionary *mention = link.isMention && seen++ < SZFriendsMentionsMax ? [self mentionForLink:link url:url]
                                                                                : nil;
        if (mention) linked++;
        [mentions addObject:mention ?: [NSNull null]];
    }
    return mentions;
}

// `segments` NO: only the plain words, for previews, without finding web links in them.
- (SZFriendsResolvedText *)resolvedText:(NSString *)text segments:(BOOL)wantsSegments {
    SZFriendsResolvedText *resolved = [[SZFriendsResolvedText alloc] init];
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(text);
    if (links.count == 0) {
        resolved.markdown = text;
        resolved.plain = text;
        resolved.segments = wantsSegments ? [self segmentsForText:text] : @[];
        return resolved;
    }
    // Clients that cannot show a mention as a link get its words as plain text (PROTOCOL.md § Capabilities).
    BOOL linked = [self.audience.capabilities containsObject:@"mentions"];
    NSArray *resolvedLinks = [self mentionsForLinks:links];
    NSMutableString *markdown = [NSMutableString string], *plain = [NSMutableString string];
    NSMutableString *run = [NSMutableString string]; // plain text waiting for its web links to be found
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array], *mentions = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSUInteger i = 0; i < links.count; i++) {
        SZFriendsTextLink *link = links[i];
        NSDictionary *mention = resolvedLinks[i] == [NSNull null] ? nil : resolvedLinks[i];
        NSString *between = [text substringWithRange:NSMakeRange(cursor, link.range.location - cursor)];
        NSString *label = mention ? mention[@"label"] : link.shownText;
        cursor = NSMaxRange(link.range);
        [markdown appendString:between];
        [plain appendString:between];
        [plain appendString:label];
        [run appendString:between];
        if (!mention || !linked) {
            [markdown appendString:SZFriendsMarkdownLiteral(label)];
            [run appendString:label];
            continue;
        }
        [markdown appendFormat:@"[%@](%@)", SZFriendsMarkdownLiteral(label), mention[@"url"]];
        if (wantsSegments && run.length) [segments addObjectsFromArray:[self segmentsForText:run]];
        [run setString:@""];
        [segments addObject:@{@"text" : label, @"mention" : @(mentions.count)}];
        [mentions addObject:mention];
    }
    NSString *tail = [text substringFromIndex:cursor];
    [markdown appendString:tail];
    [plain appendString:tail];
    [run appendString:tail];
    if (wantsSegments && (run.length || segments.count == 0)) [segments addObjectsFromArray:[self segmentsForText:run]];
    resolved.markdown = markdown;
    resolved.plain = plain;
    resolved.segments = wantsSegments ? segments : @[];
    resolved.mentions = mentions.count ? mentions : nil;
    return resolved;
}

- (SZFriendsResolvedText *)resolvedText:(NSString *)text {
    return [self resolvedText:text segments:YES];
}

- (NSString *)plainTextOf:(NSString *)text {
    return [self resolvedText:text segments:NO].plain;
}

#pragma mark - Search

// One stretch of the stored text and where it lands in the plain text. A link's visible part is its link text
// ("[@Mei Lin]"): a match there lights up the whole name shown in its place; a match only in its destination (the ID,
// the key, "szfriends") lights up nothing.
static NSDictionary *Piece(NSUInteger from, NSUInteger length, NSUInteger to, NSUInteger shown, BOOL link) {
    return @{@"from" : @(from), @"length" : @(length), @"to" : @(to), @"shown" : @(shown), @"link" : @(link)};
}

- (SZFriendsSearchHitFacts *)displayedHit:(SZFriendsSearchHitFacts *)hit {
    NSString *text = hit.text ?: @"";
    NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(text);
    if (links.count == 0) return hit;
    NSArray *resolved = [self mentionsForLinks:links];
    NSMutableString *plain = [NSMutableString string];
    NSMutableArray<NSDictionary *> *pieces = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSUInteger i = 0; i < links.count; i++) {
        SZFriendsTextLink *link = links[i];
        NSUInteger gap = link.range.location - cursor;
        [pieces addObject:Piece(cursor, gap, plain.length, gap, NO)];
        [plain appendString:[text substringWithRange:NSMakeRange(cursor, gap)]];
        NSString *label = resolved[i] == [NSNull null] ? link.shownText : resolved[i][@"label"];
        NSUInteger visible = link.isMention ? SZFriendsMarkdownLiteral(link.shownText).length + 2 : link.range.length;
        [pieces addObject:Piece(link.range.location, MIN(visible, link.range.length), plain.length, label.length, YES)];
        [plain appendString:label];
        cursor = NSMaxRange(link.range);
    }
    [pieces addObject:Piece(cursor, text.length - cursor, plain.length, text.length - cursor, NO)];
    [plain appendString:[text substringFromIndex:cursor]];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSValue *value in hit.matchRanges) {
        for (NSDictionary *piece in pieces) {
            NSUInteger from = [piece[@"from"] unsignedIntegerValue], to = [piece[@"to"] unsignedIntegerValue];
            NSRange stretch = NSMakeRange(from, [piece[@"length"] unsignedIntegerValue]);
            NSRange part = NSIntersectionRange(value.rangeValue, stretch);
            if (part.length == 0) continue;
            NSRange shown = [piece[@"link"] boolValue] ? NSMakeRange(to, [piece[@"shown"] unsignedIntegerValue])
                                                      : NSMakeRange(to + part.location - from, part.length);
            if (shown.length) [ranges addObject:[NSValue valueWithRange:shown]];
        }
    }
    if (hit.matchRanges.count && ranges.count == 0) return nil;
    SZFriendsSearchHitFacts *shown = [[SZFriendsSearchHitFacts alloc] init];
    shown.conversationID = hit.conversationID;
    shown.itemID = hit.itemID;
    shown.sentAt = hit.sentAt;
    shown.outgoing = hit.outgoing;
    shown.text = plain;
    shown.matchRanges = ranges;
    return shown;
}

#pragma mark - Composing

- (id)mentionNoteForPerson:(SZFriendsPersonFacts *)person enabled:(BOOL)enabled {
    if (![self.audience.capabilities containsObject:@"mentions"]) return nil;
    if (!enabled) return [NSNull null];
    return [self.strings text:@"mention.note" values:@{@"first" : [self firstNameForPerson:person]}];
}

- (NSNumber *)mentionableForPerson:(SZFriendsPersonFacts *)person {
    if (![self.audience.capabilities containsObject:@"mentions"]) return nil;
    // A mention carries the person's ID and key; someone without either cannot be named in one.
    return SZFriendsBool(person.relation == SZFriendsPersonRelationFriend && person.friendsID.length > 0 &&
                         person.identityKey.length == 32);
}

@end
