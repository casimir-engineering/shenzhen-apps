// A removed device's late events (ADR 0014 § What a removed computer still counts for). The device that removes another
// records how many of its events it held; our devices refuse the rest from then on. But a device that heard the
// removed one before it heard the removal already holds some of the rest: when the record reaches it, they go. Their
// items go as erased history goes (free pages wiped), and every value one of them was the last to write (a name, a
// read marker, an outbox state...) is worked out again from the events that remain, by the same merge rules, so every
// device ends with the same store whichever order things reached it.

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

// What a register holds before any event wrote it.
static SZFriendsSyncRegister *SZFriendsSyncNeverWritten(void) {
    SZFriendsSyncRegister *cleared = [[SZFriendsSyncRegister alloc] init];
    cleared.lamport = 0;
    cleared.author = [NSData data];
    cleared.value = nil;
    return cleared;
}

@implementation SZFriendsSyncEngine (Purge)

// The register an event of these kinds writes, by this device's names; nil for kinds without one (items are a set,
// chains merge, tombstones and records are their own) or a conversation not here.
- (nullable NSString *)registerKeyOfEvent:(SZFriendsSyncEvent *)event {
    switch (event.kind) {
    case SZFriendsSyncKindProfile: return @"profile";
    case SZFriendsSyncKindSetting: return [@"s/" stringByAppendingString:event.subject];
    case SZFriendsSyncKindOutbox: return [@"o/" stringByAppendingString:event.subject];
    case SZFriendsSyncKindFile: return [@"f/" stringByAppendingString:event.subject];
    case SZFriendsSyncKindPerson:
    case SZFriendsSyncKindRead: {
        SZFriendsSyncFields *fields = event.body ? [SZFriendsSyncFields fieldsWithData:event.body] : nil;
        NSString *conversation = [self conversationForScope:event.scope
                                         authorConversation:[fields stringForTag:SZFSTagConversation]];
        if (conversation == nil) return nil;
        return event.kind == SZFriendsSyncKindRead ? SZFriendsSyncReadKey(conversation)
                                                   : SZFriendsSyncPersonKey(conversation, event.subject);
    }
    default: return nil;
    }
}

- (BOOL)dropEventsOfDevice:(NSData *)deviceKey after:(uint64_t)covered {
    NSArray<SZFriendsSyncLogEvent *> *late = [self.store syncEventsOfAuthor:deviceKey afterSeq:covered];
    if (late.count == 0) return YES;
    // A change made here and not yet recorded (a name typed over the removed computer's) becomes an event of ours
    // first, so it is the last writer of its value and nothing below works it out again over it.
    [self captureLocalChanges];
    // Which values they were the last to write, read before they go.
    NSMutableDictionary<NSString *, NSNumber *> *written = [NSMutableDictionary dictionary]; // key -> kind
    NSMutableSet<NSString *> *held = [NSMutableSet set];
    for (SZFriendsSyncLogEvent *log in late) {
        SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventWithLogEvent:log];
        if (event.kind == SZFriendsSyncKindFileHeld) [held addObject:event.subject];
        NSString *key = event ? [self registerKeyOfEvent:event] : nil;
        SZFriendsSyncRegister *current = key ? [self.store syncRegisterForKey:key] : nil;
        if (current != nil && [current.author isEqualToData:deviceKey] && current.lamport == event.lamport) {
            written[key] = @(event.kind);
        }
    }
    NSArray<NSString *> *touched = [self.store purgeSyncEventsOfAuthor:deviceKey
                                                              afterSeq:covered
                                                              fileKind:SZFriendsSyncKindFile
                                                            outboxKind:SZFriendsSyncKindOutbox
                                                                 error:NULL];
    if (touched == nil) return NO;
    self.tombstones = nil;
    for (NSString *conversationID in touched) [self noteChangedConversation:conversationID];
    // It no longer holds what it claimed to after its removal.
    for (NSString *transferID in held) {
        SZFriendsSyncFileRecord *file = [self.store syncFileWithID:transferID];
        if (file == nil || ![file.holders containsObject:deviceKey]) continue;
        NSMutableArray<NSData *> *holders = [file.holders mutableCopy];
        [holders removeObject:deviceKey];
        file.holders = holders;
        [self.store saveSyncFile:file error:NULL];
        [self noteChangedConversation:file.conversationID];
    }
    for (NSString *key in [written.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [self rederiveRegister:key kind:(SZFriendsSyncKind)written[key].integerValue];
    }
    for (NSString *conversationID in self.changedConversations.copy) [self recountUnreadInConversation:conversationID];
    [self flushChanges];
    return YES;
}

// The value of `key` as the events left would have made it: cleared, then those events applied again in clock order
// under the usual rules (last writer wins; the maximum for read markers; delivered wins for outbox entries and files).
// When no event is left for it, it goes back to never written, as on a device the late events never reached: no own
// profile, no read marker (everything counts as unread again). A value this device still shows otherwise (a setting,
// a person's fields) is then a change of its own, which its next capture sends, so every device ends alike.
- (void)rederiveRegister:(NSString *)key kind:(SZFriendsSyncKind)kind {
    NSMutableArray<SZFriendsSyncEvent *> *candidates = [NSMutableArray array];
    for (SZFriendsSyncLogEvent *log in [self.store syncEventsOfKind:kind]) {
        if (log.body == nil || !log.applied) continue; // one still waiting applies in its turn anyway
        SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventWithLogEvent:log];
        if (event != nil && [[self registerKeyOfEvent:event] isEqualToString:key]) [candidates addObject:event];
    }
    if (candidates.count == 0) {
        [self clearRegister:key kind:kind];
        return;
    }
    [candidates sortUsingComparator:^NSComparisonResult(SZFriendsSyncEvent *a, SZFriendsSyncEvent *b) {
        if (a.lamport != b.lamport) return a.lamport < b.lamport ? NSOrderedAscending : NSOrderedDescending;
        return SZFriendsSyncSortedKeys(@[ a.author, b.author ]).firstObject == a.author ? NSOrderedAscending
                                                                                         : NSOrderedDescending;
    }];
    if (![self.store setSyncRegister:SZFriendsSyncNeverWritten() forKey:key error:NULL]) return;
    for (SZFriendsSyncEvent *event in candidates) [self applyEvent:event];
}

- (void)clearRegister:(NSString *)key kind:(SZFriendsSyncKind)kind {
    if (![self.store setSyncRegister:SZFriendsSyncNeverWritten() forKey:key error:NULL]) return;
    if (kind == SZFriendsSyncKindProfile) {
        self.store.profileName = nil;
        self.store.profilePicture = [SZFriendsPicture placeholder];
        [self noteChangedConversation:nil];
    } else if (kind == SZFriendsSyncKindRead) {
        [self noteChangedConversation:[key substringFromIndex:SZFriendsSyncReadKey(@"").length]];
    }
}

@end

NS_ASSUME_NONNULL_END
