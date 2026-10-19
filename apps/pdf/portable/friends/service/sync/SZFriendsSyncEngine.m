// The sync engine: signing our events, taking in our other devices' events, applying them in batches, and the
// deletion that erases chat history on every device (SZFriendsSync.h). Capture is SZFriendsSyncCapture.m, the merge
// rules SZFriendsSyncApply.m, file copies SZFriendsSyncFiles.m.

#import <sodium.h>

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Events applied per transaction: one commit (and one fsync) per batch rather than per event.
static const NSUInteger SZFriendsSyncApplyBatch = 200;

@implementation SZFriendsSyncEngine {
    uint64_t _nextSeq;   // 0: read from the store before the next event
    uint64_t _lamport;
    NSMutableSet<NSString *> *_changedConversations;
}

- (instancetype)initWithStore:(SZFriendsStore *)store
                     identity:(SZFriendsIdentity *)identity
            receivedDirectory:(NSString *)receivedDirectory {
    if ((self = [super init])) {
        _store = store;
        _identity = identity;
        _receivedDirectory = [receivedDirectory copy];
        _changedConversations = [NSMutableSet set];
        _clock = ^NSDate * { return [NSDate date]; };
    }
    return self;
}

- (NSMutableSet<NSString *> *)changedConversations {
    return _changedConversations;
}

#pragma mark - Who we are

// From the store's index of our chain (no signature checks): this device's root while the chain authorizes it.
- (nullable NSData *)ownRootKey {
    return [self.store rootKeyForDeviceKey:self.identity.publicKey];
}

- (nullable NSData *)rootKey {
    return [self ownRootKey];
}

- (NSArray<SZFriendsDeviceRecord *> *)ownDevices {
    NSData *root = [self ownRootKey];
    return root ? [self.store devicesOfRootKey:root] : @[];
}

- (BOOL)isActive {
    return [self ownDevices].count >= 2;
}

- (NSArray<NSData *> *)otherDeviceKeys {
    NSMutableArray<NSData *> *keys = [NSMutableArray array];
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        BOOL other = ![device.deviceKey isEqualToData:self.identity.publicKey];
        if (device.state == SZFriendsChainDeviceAuthorized && other) {
            [keys addObject:device.deviceKey];
        }
    }
    return keys;
}

- (NSData *)ownChainFingerprint {
    NSMutableData *index = [NSMutableData data];
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        [index appendData:device.deviceKey];
        NSString *line = [NSString stringWithFormat:@"%ld|%@|%@|", (long)device.state, device.name, device.system];
        [index appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
    return SZFriendsSyncDigest(index);
}

- (nullable NSData *)ensureOwnDevicesSecret {
    NSData *held = [self ownDevicesSecret];
    if (held != nil || !self.active) return held;
    BOOL draws = NO;
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        if (!device.isRoot) continue;
        draws = [device.deviceKey isEqualToData:self.identity.publicKey] ||
                device.state != SZFriendsChainDeviceAuthorized;
    }
    // The first device draws it and the others learn it by sync (if the first was revoked, any device may; should two
    // draw at once, the later clock's wins on both).
    if (!draws) return nil;
    NSMutableData *secret = [NSMutableData dataWithLength:32];
    randombytes_buf(secret.mutableBytes, secret.length);
    return [self.store setSyncState:secret forKey:SZFriendsSyncStateDevicesSecret error:NULL] ? secret : nil;
}

- (nullable NSData *)ownDevicesSecret {
    id secret = [self.store syncStateForKey:SZFriendsSyncStateDevicesSecret];
    return [secret isKindOfClass:[NSData class]] && [(NSData *)secret length] == 32 ? secret : nil;
}

#pragma mark - Our events

- (void)resetCounters {
    _nextSeq = 0;
}

- (void)reloadCounters {
    _nextSeq = [[self.store syncVector][self.identity.publicKey] unsignedLongLongValue] + 1;
    _lamport = [self.store syncLamport];
}

- (nullable SZFriendsSyncEvent *)recordKind:(SZFriendsSyncKind)kind
                                      scope:(NSString *)scope
                                    subject:(NSString *)subject
                                       body:(NSData *)body
                                      error:(NSError **)error {
    NSData *root = [self ownRootKey];
    if (root == nil) {
        SZFriendsSyncFail(error, SZFriendsSyncErrorInactive, @"no own device chain");
        return nil;
    }
    if (body.length > SZFriendsSyncBodyMax || !SZFriendsSyncLabelIsValid(scope) ||
        !SZFriendsSyncLabelIsValid(subject)) {
        SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"an event outside its limits");
        return nil;
    }
    if (_nextSeq == 0) [self reloadCounters];
    SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventSignedBy:self.identity
                                                          rootKey:root
                                                             kind:kind
                                                              seq:_nextSeq
                                                          lamport:_lamport + 1
                                                             date:self.clock()
                                                            scope:scope
                                                          subject:subject
                                                             body:body];
    SZFriendsSyncLogEvent *log = event.logEvent;
    log.applied = YES; // our own change is already in the store
    BOOL appended = NO;
    if (![self.store appendSyncEvent:log appended:&appended error:error] || !appended) {
        _nextSeq = 0; // the log moved under us: read again before the next one
        if (error && *error == nil) *error = SZFriendsSyncMakeError(SZFriendsSyncErrorOutOfOrder, @"not appended");
        return nil;
    }
    _nextSeq += 1;
    _lamport += 1;
    return event;
}

- (NSUInteger)captureLocalChanges {
    if (!self.active) return 0;
    _nextSeq = 0;
    NSUInteger recorded = [self captureChanges];
    _nextSeq = 0; // a rolled-back batch would leave the counters ahead of the log
    if (recorded > 0 && self.onNewEvents) self.onNewEvents();
    return recorded;
}

#pragma mark - Their events

- (BOOL)receiveEvents:(NSArray<SZFriendsSyncEvent *> *)events error:(NSError **)error {
    NSArray<SZFriendsDeviceRecord *> *devices = [self ownDevices];
    if (devices.count < 2) return SZFriendsSyncFail(error, SZFriendsSyncErrorInactive, @"sync is off");
    NSMutableDictionary<NSData *, NSNumber *> *states = [NSMutableDictionary dictionary];
    NSMutableSet<NSData *> *revoked = [NSMutableSet set];
    for (SZFriendsDeviceRecord *device in devices) {
        states[device.deviceKey] = @(device.state);
        if (device.state == SZFriendsChainDeviceRevoked) [revoked addObject:device.deviceKey];
    }
    // Our own changes first: a capture after these events would read their effects as ours.
    [self captureLocalChanges];
    // A revoked device's events count only as far as the device that revoked it had them: what it signed after its
    // removal (or claims to have signed before, unseen) is never appended, whoever forwards it.
    NSDictionary<NSData *, NSNumber *> *coverage = nil;
    NSMutableSet<NSData *> *beyond = [NSMutableSet set];
    uint64_t clock = [self.store syncLamport];
    BOOL ok = YES, appendedAny = NO;
    for (SZFriendsSyncEvent *event in events) {
        // A device the chain revoked signed its events while it spoke for us; ones never validly added did not. A
        // void device (added only by a removed one, on a branch that had not seen the removal) never spoke for us:
        // its events are left out, and the rest of the batch still counts.
        NSInteger state = [states[event.author] integerValue];
        if (state == SZFriendsChainDeviceVoid) continue;
        if (state != SZFriendsChainDeviceAuthorized && state != SZFriendsChainDeviceRevoked) {
            ok = SZFriendsSyncFail(error, SZFriendsSyncErrorUnauthorized, @"an event from a device not ours");
            break;
        }
        if (state == SZFriendsChainDeviceRevoked) {
            if (coverage == nil) coverage = [self revocationCoverageWithEvents:events revoked:revoked];
            NSNumber *covered = coverage[event.author];
            if ([beyond containsObject:event.author] || covered == nil || event.seq > covered.unsignedLongLongValue) {
                [beyond addObject:event.author]; // and every later one of that author
                continue;
            }
        }
        if (event.lamport > clock && event.lamport - clock > SZFriendsSyncLamportMargin) {
            ok = SZFriendsSyncFail(error, SZFriendsSyncErrorForged, @"an event whose clock is far ahead of ours");
            break;
        }
        SZFriendsSyncLogEvent *log = event.logEvent;
        log.applied = NO;
        BOOL appended = NO;
        NSError *inner = nil;
        if (![self.store appendSyncEvent:log appended:&appended error:&inner]) {
            ok = SZFriendsSyncFail(error, SZFriendsSyncErrorOutOfOrder, inner.localizedDescription ?: @"a gap");
            break;
        }
        appendedAny = appendedAny || appended;
        if (appended && event.lamport > clock) clock = event.lamport;
    }
    _nextSeq = 0;
    if (appendedAny) {
        [self applyPendingEvents];
        if (self.onNewEvents) self.onNewEvents();
    }
    return ok;
}

- (NSUInteger)applyPendingEvents {
    NSUInteger total = 0;
    self.tombstones = nil;
    while (YES) {
        NSArray<SZFriendsSyncLogEvent *> *pending = [self.store unappliedSyncEvents];
        NSUInteger applied = 0;
        NSMutableArray<SZFriendsSyncEvent *> *batch = [NSMutableArray array];
        for (SZFriendsSyncLogEvent *log in pending) {
            SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventWithLogEvent:log];
            if (event == nil) continue;
            if ([self appliesAlone:event]) {
                applied += [self applyBatch:batch];
                [batch removeAllObjects];
                if ([self applyEvent:event] == SZFriendsSyncApplyDone &&
                    [self.store markSyncEventApplied:event.author seq:event.seq error:NULL]) {
                    applied++;
                    // A removal record may have taken events further down this list from the log: read it again.
                    if (event.kind == SZFriendsSyncKindRevocation) break;
                }
                continue;
            }
            [batch addObject:event];
            if (batch.count == SZFriendsSyncApplyBatch) {
                applied += [self applyBatch:batch];
                [batch removeAllObjects];
            }
        }
        applied += [self applyBatch:batch];
        total += applied;
        if (applied == 0) break;
    }
    for (NSString *conversationID in self.changedConversations.copy) [self recountUnreadInConversation:conversationID];
    [self flushChanges];
    return total;
}

// Outside any batch: deletions compact the database, which no transaction may surround, and the profile and settings
// are read back through the store's read connection, which sees only what was committed. All are rare.
- (BOOL)appliesAlone:(SZFriendsSyncEvent *)event {
    switch (event.kind) {
    case SZFriendsSyncKindTombstone:
    case SZFriendsSyncKindProfile:
    case SZFriendsSyncKindSetting:
    case SZFriendsSyncKindRevocation:
    case SZFriendsSyncKindChain: return YES;
    case SZFriendsSyncKindItem: {
        if (event.body == nil) return YES;
        SZFriendsSyncFields *fields = [SZFriendsSyncFields fieldsWithData:event.body];
        NSString *conversation = [self conversationForScope:event.scope
                                         authorConversation:[fields stringForTag:SZFSTagConversation]];
        return conversation != nil && [self tombstoneCovers:event conversation:conversation];
    }
    default: return NO;
    }
}

- (NSUInteger)applyBatch:(NSArray<SZFriendsSyncEvent *> *)batch {
    if (batch.count == 0) return 0;
    __block NSUInteger applied = 0;
    BOOL committed = [self.store performSyncTransaction:^BOOL(NSError **error) {
        for (SZFriendsSyncEvent *event in batch) {
            if ([self applyEvent:event] != SZFriendsSyncApplyDone) continue;
            if ([self.store markSyncEventApplied:event.author seq:event.seq error:error]) applied++;
        }
        return YES;
    } error:NULL];
    return committed ? applied : 0;
}

#pragma mark - Deleting history

- (BOOL)deleteHistoryInConversation:(nullable NSString *)conversationID error:(NSError **)error {
    if (!self.active) return [self.store deleteHistoryInConversation:conversationID error:error];
    // Everything here becomes an event first, so the deletion's vector covers every item this device shows.
    [self captureLocalChanges];
    NSString *scope = @"";
    if (conversationID != nil) {
        SZFriendsPersonRecord *person = [self.store syncPersonWithConversationID:conversationID];
        if (person == nil) {
            if (error) {
                *error = [NSError errorWithDomain:SZFriendsStoreErrorDomain code:SZFriendsStoreErrorNotFound
                                         userInfo:@{NSLocalizedDescriptionKey : @"no such conversation"}];
            }
            return NO;
        }
        scope = SZFriendsSyncRefForPerson(person);
    }
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:conversationID forTag:SZFSTagConversation];
    [fields setData:SZFriendsSyncEncodeVector([self.store syncVector]) forTag:2];
    __block SZFriendsSyncEvent *tombstone = nil;
    _nextSeq = 0;
    BOOL ok = [self.store performSyncTransaction:^BOOL(NSError **inner) {
        tombstone = [self recordKind:SZFriendsSyncKindTombstone scope:scope subject:@"" body:fields.encodedData
                               error:inner];
        return tombstone != nil;
    } error:error];
    _nextSeq = 0;
    if (!ok) return NO;
    self.tombstones = nil;
    if (![self applyTombstone:tombstone]) {
        if (error) *error = SZFriendsSyncMakeError(SZFriendsSyncErrorMalformed, @"the deletion did not apply");
        return NO;
    }
    [self flushChanges];
    if (self.onNewEvents) self.onNewEvents();
    return YES;
}

#pragma mark - Exchange support

- (SZFriendsSyncVector *)vector {
    return [self.store syncVector];
}

// Authors whose events we pass on: devices our chain authorizes or removed (whose events before their removal count).
- (NSSet<NSData *> *)authorsOffered {
    NSMutableSet<NSData *> *authors = [NSMutableSet set];
    for (SZFriendsDeviceRecord *device in [self ownDevices]) {
        if (device.state == SZFriendsChainDeviceAuthorized || device.state == SZFriendsChainDeviceRevoked) {
            [authors addObject:device.deviceKey];
        }
    }
    return authors;
}

- (SZFriendsSyncVector *)offeredVector {
    NSSet<NSData *> *authors = [self authorsOffered];
    NSMutableDictionary<NSData *, NSNumber *> *offered = [NSMutableDictionary dictionary];
    SZFriendsSyncVector *held = [self.store syncVector];
    for (NSData *author in held) {
        if ([authors containsObject:author]) offered[author] = held[author];
    }
    return offered;
}

- (NSArray<SZFriendsSyncEvent *> *)eventsMissingFrom:(SZFriendsSyncVector *)vector limit:(NSUInteger)limit {
    // Events of a device that is neither ours nor removed (a void one) are never offered: asked as if held.
    NSSet<NSData *> *authors = [self authorsOffered];
    NSMutableDictionary<NSData *, NSNumber *> *asked = [vector mutableCopy];
    for (NSData *author in [self.store syncVector]) {
        if (![authors containsObject:author]) asked[author] = @(UINT64_MAX);
    }
    NSMutableArray<SZFriendsSyncEvent *> *events = [NSMutableArray array];
    for (SZFriendsSyncLogEvent *log in [self.store syncEventsMissingFrom:asked limit:limit]) {
        SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventWithLogEvent:log];
        if (event != nil) [events addObject:event];
    }
    return events;
}

#pragma mark - Conversations

- (nullable NSString *)conversationForScope:(NSString *)scope authorConversation:(nullable NSString *)conversation {
    SZFriendsStore *store = self.store;
    if ([scope isEqualToString:SZFriendsYouConversationID]) {
        return [store ensureYouConversation:NULL] ? SZFriendsYouConversationID : nil;
    }
    if ([scope hasPrefix:@"k:"]) {
        NSData *key = SZFriendsSyncBytesFromHex([scope substringFromIndex:2]);
        if (key.length != 32) return nil;
        SZFriendsPersonRecord *person = [store syncPersonWithIdentityKey:key];
        if (person != nil) return person.conversationID;
        // Their key may not have reached our copy yet (an Add by ID answered on the other device): the conversation
        // the author named, if it has no key of its own.
        SZFriendsPersonRecord *named = conversation ? [store syncPersonWithConversationID:conversation] : nil;
        return named != nil && named.identityKey == nil ? named.conversationID : nil;
    }
    if ([scope hasPrefix:@"c:"]) {
        NSString *named = [scope substringFromIndex:2];
        if ([store syncPersonWithConversationID:named] != nil) return named;
        return conversation && [store syncPersonWithConversationID:conversation] ? conversation : nil;
    }
    return nil;
}

- (void)noteChangedConversation:(nullable NSString *)conversationID {
    if (conversationID == nil) self.profileChanged = YES;
    else [_changedConversations addObject:conversationID];
}

- (void)flushChanges {
    if (_changedConversations.count == 0 && !self.profileChanged) return;
    NSSet<NSString *> *changed = [_changedConversations copy];
    [_changedConversations removeAllObjects];
    self.profileChanged = NO;
    if (self.onChange) self.onChange(changed);
}

@end

NS_ASSUME_NONNULL_END
