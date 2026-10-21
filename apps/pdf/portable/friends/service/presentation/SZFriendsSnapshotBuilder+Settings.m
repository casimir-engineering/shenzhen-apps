// Shenzhen Friends snapshot builder: the Settings section and local search results (conversation search, Cmd+K).
//
// Settings describes what each choice does from the person's side; the Enable checkbox and the disclosure belong to
// the host adapter because they show while Friends is off and no helper runs (PROTOCOL.md § settings).

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

// Names spelled out in the automatic-acceptance summary before it switches to a count.
static const NSUInteger SZFriendsNamedAutoAcceptLimit = 3;

@implementation SZFriendsSnapshotBuilder (SZFriendsSettings)

- (NSString *)autoAcceptNoteFor:(NSArray<SZFriendsPersonFacts *> *)enabled friendCount:(NSUInteger)friendCount {
    SZFriendsStrings *s = self.strings;
    if (friendCount == 0) return [s text:@"settings.auto.note.no_friends"];
    if (enabled.count == 0) return [s text:@"settings.auto.note.none"];
    if (enabled.count == friendCount && friendCount > 1) return [s text:@"settings.auto.note.all"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (SZFriendsPersonFacts *person in enabled) [names addObject:[self titleForPerson:person]];
    NSString *who;
    if (names.count <= SZFriendsNamedAutoAcceptLimit) {
        who = [s joinedList:names];
    } else {
        NSArray<NSString *> *shown = [names subarrayWithRange:NSMakeRange(0, SZFriendsNamedAutoAcceptLimit - 1)];
        NSString *rest = [s text:@"settings.auto.others" count:(NSInteger)(names.count - shown.count) values:nil];
        who = [s joinedList:[shown arrayByAddingObject:rest]];
    }
    NSString *key = enabled.count == friendCount ? @"settings.auto.note.only" : @"settings.auto.note.some";
    return [s text:key values:@{@"names" : who}];
}

// Where received files go. With received.folder the row names the folder and offers Change…, which the view answers
// with a folder picker and set_received_folder (PROTOCOL.md § Views, settings).
- (NSDictionary<NSString *, id> *)receivedFolderWithProfile:(SZFriendsProfileFacts *)profile
                                                     reveal:(NSDictionary<NSString *, id> *)reveal {
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *received = [@{
        @"label" : [s text:@"settings.received.label"],
        @"note" : [s text:@"settings.received.note"],
        @"action" : reveal
    } mutableCopy];
    if ([self.audience.helperCapabilities containsObject:@"received.folder"]) {
        received[@"value"] = profile.receivedFolderName.length ? profile.receivedFolderName
                                                               : [s text:@"settings.received.default"];
        received[@"path"] = profile.receivedDirectory;
        received[@"change"] = [self action:@"choose_received_folder" label:[s text:@"settings.received.change"]
                                     style:@"secondary"];
        // The last file went elsewhere because this folder could not take it: said until one is saved here.
        if (profile.receivedFallback == SZFriendsReceivedFallbackFactsDownloads) {
            received[@"note"] = [s text:@"settings.received.note.fallback.downloads"];
        } else if (profile.receivedFallback == SZFriendsReceivedFallbackFactsKept) {
            received[@"note"] = [s text:@"settings.received.note.fallback.kept"
                                 values:@{@"app" : self.audience.appName}];
        }
    }
    return received;
}

- (NSDictionary<NSString *, id> *)buildSettingsWithProfile:(SZFriendsProfileFacts *)profile
                                               people:(NSArray<SZFriendsPersonFacts *> *)people {
    SZFriendsStrings *s = self.strings;
    NSString *name = [profile.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<SZFriendsPersonFacts *> *on = [NSMutableArray array], *off = [NSMutableArray array];
    for (SZFriendsPersonFacts *person in [self peopleByLatestInteraction:people]) {
        if (person.relation != SZFriendsPersonRelationFriend) continue; // the switch exists for friends only
        [person.autoAccept ? on : off addObject:person];
    }
    NSMutableArray *switches = [NSMutableArray array];
    for (SZFriendsPersonFacts *person in [on arrayByAddingObjectsFromArray:off]) {
        [switches addObject:@{
            @"conversation_id" : person.conversationID,
            @"title" : [self titleForPerson:person],
            @"avatar" : [self avatarForPerson:person],
            @"enabled" : SZFriendsBool(person.autoAccept)
        }];
    }
    NSMutableDictionary *reveal = [self action:@"show_file"
                                         label:[s text:@"action.show_in" values:@{@"app" : self.audience.revealIn}]
                                         style:@"secondary"];
    reveal[@"path"] = profile.receivedDirectory;
    NSMutableDictionary *settings = [@{
        @"name" : @{
            @"label" : [s text:@"settings.name.label"],
            @"note" : [s text:@"settings.name.note"],
            @"value" : name.length ? name : [NSNull null],
            @"placeholder" : [s text:@"footer.name_placeholder"]
        },
        @"id" : @{
            @"label" : [s text:@"profile.id.label"],
            @"note" : [s text:@"settings.id.note"],
            @"friends_id" : profile.friendsID,
            @"copy_label" : [s text:@"static.copy"]
        },
        @"received" : [self receivedFolderWithProfile:profile reveal:reveal],
        @"auto_accept" : @{
            @"label" : [s text:@"settings.auto.label"],
            @"note" : [self autoAcceptNoteFor:on friendCount:on.count + off.count],
            @"action_label" : [s text:@"settings.auto.action"],
            @"friends" : switches
        },
        @"history" : @{
            @"label" : [s text:@"settings.history.label"],
            @"note" : [s text:[self everyComputerKey:@"settings.history.note"]],
            @"action_label" : [s text:@"settings.history.action"],
            @"confirm" : [self confirmWithTitle:@"settings.history.confirm.title"
                                           body:[self everyComputerKey:
                                                          [self deletionBodyKey:@"settings.history.confirm.body"]]
                                   confirmLabel:@"settings.history.confirm.button"
                                         values:nil
                                    destructive:YES]
        },
        @"reset" : @{
            @"label" : [s text:@"settings.reset.label"],
            @"note" : [s text:@"settings.reset.note"],
            @"action_label" : [s text:@"settings.reset.action"],
            @"confirm" : [self confirmWithTitle:@"settings.reset.confirm.title"
                                           body:[self deletionBodyKey:@"settings.reset.confirm.body"]
                                   confirmLabel:@"settings.reset.confirm.button"
                                         values:nil
                                    destructive:YES]
        }
    } mutableCopy];
    settings[@"join"] = self.devices ? [self settingsJoin] : nil; // using an existing profile here (+Devices)
    return settings;
}

// Deleting history or resetting leaves what the host's AI chat already wrote: an answer there that quoted a friend is
// the host's, so the confirmation says so whenever this host's AI chat may read Friends chats (assistant.chats).
// On several computers, the words that say history goes from every one of them (+Devices).
- (NSString *)everyComputerKey:(NSString *)key {
    return self.deletesOnEveryComputer ? [key stringByAppendingString:@".devices"] : key;
}

- (NSString *)deletionBodyKey:(NSString *)key {
    if (![self.audience.capabilities containsObject:@"assistant.chats"]) return key;
    return [key stringByAppendingString:@".assistant"];
}

// Context around the first match, so a hit deep inside a long message still shows why it matched.
static const NSUInteger SZFriendsExcerptContext = 60;

- (NSArray *)excerptForHit:(SZFriendsSearchHitFacts *)hit {
    NSString *text = hit.text ?: @"";
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSValue *value in hit.matchRanges) {
        NSRange range = value.rangeValue;
        if (range.length && NSMaxRange(range) <= text.length) [ranges addObject:value];
    }
    [ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
      return a.rangeValue.location < b.rangeValue.location ? NSOrderedAscending
             : a.rangeValue.location > b.rangeValue.location ? NSOrderedDescending
                                                             : NSOrderedSame;
    }];
    NSUInteger start = 0, end = text.length;
    if (ranges.count && text.length > 2 * SZFriendsExcerptContext) {
        NSRange first = ranges[0].rangeValue;
        start = first.location > SZFriendsExcerptContext ? first.location - SZFriendsExcerptContext : 0;
        end = MIN(text.length, NSMaxRange(first) + 2 * SZFriendsExcerptContext);
        NSRange whole = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start, end - start)];
        start = whole.location;
        end = NSMaxRange(whole);
    }
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSUInteger cursor = start;
    if (start > 0) [segments addObject:@{@"text" : @"…"}];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        if (range.location < cursor || NSMaxRange(range) > end) continue; // overlapping or outside the window
        if (range.location > cursor)
            [segments addObject:@{@"text" : [text substringWithRange:NSMakeRange(cursor, range.location - cursor)]}];
        [segments addObject:@{@"text" : [text substringWithRange:range], @"match" : @YES}];
        cursor = NSMaxRange(range);
    }
    if (cursor < end) [segments addObject:@{@"text" : [text substringWithRange:NSMakeRange(cursor, end - cursor)]}];
    if (end < text.length) [segments addObject:@{@"text" : @"…"}];
    if (segments.count == 0) [segments addObject:@{@"text" : text}];
    return segments;
}

- (NSDictionary<NSString *, id> *)buildSearchResultWithHits:(NSArray<SZFriendsSearchHitFacts *> *)hits
                                                people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people
                                                  more:(BOOL)more
                                                   now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSMutableArray *results = [NSMutableArray array];
    for (SZFriendsSearchHitFacts *stored in hits) {
        SZFriendsPersonFacts *person = people[stored.conversationID];
        // A mention's excerpt says "@Name"; a hit that matched only a mention's hidden ID or key is no hit at all.
        SZFriendsSearchHitFacts *hit = [self displayedHit:stored];
        if (!person || !hit) continue; // a hit in a conversation deleted meanwhile, or in nothing anyone sees
        NSString *title = [self titleForPerson:person];
        [results addObject:@{
            @"conversation_id" : hit.conversationID,
            @"message_id" : hit.itemID,
            @"conversation_title" : title,
            @"avatar" : [self avatarForPerson:person],
            @"sender_label" : hit.outgoing ? [s text:@"search.sender.you"] : title,
            @"time_label" : [s timeLabelForDate:hit.sentAt now:now],
            @"excerpt" : [self excerptForHit:hit]
        }];
    }
    return @{
        @"results" : results,
        @"more" : SZFriendsBool(more),
        @"empty_label" : results.count ? [NSNull null] : [s text:@"search.empty"]
    };
}

@end
