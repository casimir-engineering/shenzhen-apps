// The discovery merger (ADR 0004 § The merger): sightings from every adapter in, one candidate per person out.
// Pure: no radios and no clock; every date arrives as an argument.

#import "service/discovery/SZFriendsDiscovery.h"

const NSTimeInterval SZFriendsBonjourRemovalGrace = 30;
const NSTimeInterval SZFriendsBluetoothSightingLife = 90;

static NSString *HexString(NSData *data) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

@implementation SZFriendsSighting

- (instancetype)initWithMethod:(SZFriendsDiscoveryMethod)method
                         route:(SZFriendsRouteMethod)route
                    endpointID:(NSString *)endpointID
                   presenceTag:(NSData *)presenceTag
                  callbackTags:(NSArray<NSData *> *)callbackTags
                      isPublic:(BOOL)isPublic
                        seenAt:(NSDate *)seenAt {
    if ((self = [super init])) {
        _method = method;
        _route = route;
        _endpointID = [endpointID copy];
        _presenceTag = [presenceTag copy];
        _callbackTags = [[NSArray alloc] initWithArray:callbackTags copyItems:YES];
        _isPublic = isPublic;
        _seenAt = [seenAt copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<sighting %ld %@ route %ld tag %@%@>", (long)self.method, self.endpointID,
                                      (long)self.route, self.presenceTag ? HexString(self.presenceTag) : @"-",
                                      self.isPublic ? @" public" : @""];
}

@end

@interface SZFriendsCandidate ()
- (instancetype)initWithID:(NSString *)candidateID
            conversationID:(NSString *)conversationID
                  isPublic:(BOOL)isPublic
                 sightings:(NSArray<SZFriendsSighting *> *)sightings
               identityKey:(NSData *)identityKey;
@end

@implementation SZFriendsCandidate

- (instancetype)initWithID:(NSString *)candidateID
            conversationID:(NSString *)conversationID
                  isPublic:(BOOL)isPublic
                 sightings:(NSArray<SZFriendsSighting *> *)sightings
               identityKey:(NSData *)identityKey {
    if ((self = [super init])) {
        _candidateID = [candidateID copy];
        _conversationID = [conversationID copy];
        _isPublic = isPublic;
        _sightings = [sightings copy];
        _identityKey = [identityKey copy];
    }
    return self;
}

- (BOOL)isIdentified {
    return self.conversationID != nil || self.identityKey != nil;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<candidate %@ conversation %@%@ %@>", self.candidateID,
                                      self.conversationID ?: @"-", self.isPublic ? @" public" : @"", self.sightings];
}

@end

// Everything the merger knows about one (method, endpoint): the newest sighting, when it was removed, what its
// tags matched and who a handshake said it is.
@interface SZFriendsMergerEntry : NSObject
@property(nonatomic) SZFriendsSighting *sighting;
@property(nonatomic, nullable) NSDate *removedAt;
@property(nonatomic, nullable, copy) NSString *matchedConversationID;
@property(nonatomic, nullable, copy) NSData *identityKey;
@property(nonatomic, nullable, copy) NSString *identifiedConversationID;
@property(nonatomic, nullable, copy) NSString *candidateID;
@end

@implementation SZFriendsMergerEntry

- (NSDate *)expiresAt {
    if (self.sighting.method == SZFriendsDiscoveryMethodBluetooth) {
        return [self.sighting.seenAt dateByAddingTimeInterval:SZFriendsBluetoothSightingLife];
    }
    return self.removedAt ? [self.removedAt dateByAddingTimeInterval:SZFriendsBonjourRemovalGrace] : nil;
}

@end

@implementation SZFriendsDiscoveryMerger {
    NSMutableDictionary<NSString *, SZFriendsMergerEntry *> *_entries; // "method|endpointID"
    NSMutableDictionary<NSString *, NSNumber *> *_sequenceByCandidateID;
    uint64_t _nextSequence;
    NSArray<SZFriendsCandidate *> *_candidates;
    NSArray<SZFriendsCandidate *> *_unmatchedDevices;
    NSString *_signature;
}

- (instancetype)initWithTagMatcher:(SZFriendsTagMatcher)tagMatcher {
    if ((self = [super init])) {
        _tagMatcher = [tagMatcher copy];
        _entries = [NSMutableDictionary dictionary];
        _sequenceByCandidateID = [NSMutableDictionary dictionary];
        _candidates = @[];
        _unmatchedDevices = @[];
        _signature = @"";
    }
    return self;
}

static NSString *EntryKey(SZFriendsDiscoveryMethod method, NSString *endpointID) {
    return [NSString stringWithFormat:@"%ld|%@", (long)method, endpointID];
}

- (void)setTagMatcher:(SZFriendsTagMatcher)tagMatcher {
    _tagMatcher = [tagMatcher copy];
    for (SZFriendsMergerEntry *entry in _entries.allValues) [self matchEntry:entry];
    [self rebuild];
}

- (void)matchEntry:(SZFriendsMergerEntry *)entry {
    SZFriendsSighting *sighting = entry.sighting;
    NSString *match = sighting.presenceTag ? self.tagMatcher(sighting.presenceTag) : nil;
    // The presence tag says who the device is; a callback tag says only that someone who asked for us by ID is
    // there, so it counts only when the presence tag is nobody we know.
    for (NSData *tag in sighting.callbackTags) {
        if (match) break;
        match = self.tagMatcher(tag);
    }
    entry.matchedConversationID = match;
}

- (void)addSighting:(SZFriendsSighting *)sighting {
    NSString *key = EntryKey(sighting.method, sighting.endpointID);
    SZFriendsMergerEntry *entry = _entries[key];
    if (entry) {
        // Out of order: an older observation never overwrites a newer one, and an add older than the removal
        // that followed it does not revive the endpoint.
        if ([sighting.seenAt compare:entry.sighting.seenAt] == NSOrderedAscending) return;
        if (entry.removedAt && [sighting.seenAt compare:entry.removedAt] == NSOrderedAscending) return;
    } else {
        entry = [SZFriendsMergerEntry new];
        _entries[key] = entry;
    }
    entry.sighting = sighting;
    entry.removedAt = nil; // seen again within the grace: the loss was a flap
    [self matchEntry:entry];
    [self rebuild];
}

- (void)removeEndpoint:(NSString *)endpointID method:(SZFriendsDiscoveryMethod)method atDate:(NSDate *)date {
    SZFriendsMergerEntry *entry = _entries[EntryKey(method, endpointID)];
    if (!entry) return;
    if ([date compare:entry.sighting.seenAt] == NSOrderedAscending) return; // older than the newest sighting
    if (entry.removedAt) return; // a repeated removal must not restart, and so extend, the grace
    entry.removedAt = date;
    [self rebuild];
}

- (BOOL)expireAtDate:(NSDate *)now {
    NSUInteger before = self.generation;
    for (NSString *key in _entries.allKeys) {
        NSDate *expiry = [_entries[key] expiresAt];
        if (expiry && [now compare:expiry] != NSOrderedAscending) [_entries removeObjectForKey:key];
    }
    [self rebuild];
    return self.generation != before;
}

- (void)identifyEndpoint:(NSString *)endpointID
                  method:(SZFriendsDiscoveryMethod)method
             identityKey:(NSData *)identityKey
          conversationID:(NSString *)conversationID {
    SZFriendsMergerEntry *entry = _entries[EntryKey(method, endpointID)];
    if (!entry) return;
    entry.identityKey = identityKey;
    entry.identifiedConversationID = conversationID;
    [self rebuild];
}

- (NSArray<SZFriendsCandidate *> *)candidates {
    return _candidates;
}

- (NSArray<SZFriendsCandidate *> *)unmatchedDevices {
    return _unmatchedDevices;
}

- (NSArray<SZFriendsCandidate *> *)identifiedCandidates {
    return [_candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SZFriendsCandidate *c,
                                                                                         NSDictionary *bindings) {
                            (void)bindings;
                            return c.isIdentified;
                        }]];
}

- (SZFriendsCandidate *)candidateWithID:(NSString *)candidateID {
    for (SZFriendsCandidate *candidate in [_candidates arrayByAddingObjectsFromArray:_unmatchedDevices]) {
        if ([candidate.candidateID isEqualToString:candidateID]) return candidate;
    }
    return nil;
}

- (NSDate *)nextExpiry {
    NSDate *next = nil;
    for (SZFriendsMergerEntry *entry in _entries.allValues) {
        NSDate *expiry = entry.expiresAt;
        if (expiry && (!next || [expiry compare:next] == NSOrderedAscending)) next = expiry;
    }
    return next;
}

#pragma mark - Grouping

// Which person an endpoint belongs to. "c:" a conversation (tag match or handshake), "k:" an identity key not in
// the list, "e:" an unidentified public endpoint (each its own candidate: entry names are never identity),
// "t:" / "u:" a hidden device nobody matches (one per tag, so a stranger seen on both methods is one device).
static NSString *GroupKey(NSString *entryKey, SZFriendsMergerEntry *entry) {
    NSString *conversation = entry.matchedConversationID ?: entry.identifiedConversationID;
    if (conversation) return [@"c:" stringByAppendingString:conversation];
    if (entry.identityKey) return [@"k:" stringByAppendingString:HexString(entry.identityKey)];
    if (entry.sighting.isPublic) return [@"e:" stringByAppendingString:entryKey];
    if (entry.sighting.presenceTag) return [@"t:" stringByAppendingString:HexString(entry.sighting.presenceTag)];
    return [@"u:" stringByAppendingString:entryKey];
}

// Best route first, by rank (an Internet sighting before a Bluetooth one, though its number is larger).
static NSComparisonResult CompareSightings(SZFriendsMergerEntry *a, SZFriendsMergerEntry *b) {
    NSInteger rankA = SZFriendsRouteRank(a.sighting.route), rankB = SZFriendsRouteRank(b.sighting.route);
    if (rankA != rankB) return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
    // A lingering endpoint keeps the route icon steady but is the worse one to dial.
    if ((a.removedAt == nil) != (b.removedAt == nil)) return a.removedAt == nil ? NSOrderedAscending
                                                                                 : NSOrderedDescending;
    NSComparisonResult newest = [b.sighting.seenAt compare:a.sighting.seenAt];
    if (newest != NSOrderedSame) return newest;
    return [a.sighting.endpointID compare:b.sighting.endpointID];
}

- (NSString *)newCandidateID {
    // Random rather than a counter, so an id a client still holds from before a helper restart cannot name
    // someone else. [A-Za-z0-9_-], as PROTOCOL.md requires of nearby ids.
    uint8_t bytes[12];
    arc4random_buf(bytes, sizeof bytes);
    NSString *candidateID = [@"n" stringByAppendingString:HexString([NSData dataWithBytes:bytes length:sizeof bytes])];
    _sequenceByCandidateID[candidateID] = @(_nextSequence++);
    return candidateID;
}

- (void)rebuild {
    NSMutableDictionary<NSString *, NSMutableArray<SZFriendsMergerEntry *> *> *groups =
        [NSMutableDictionary dictionary];
    for (NSString *entryKey in [_entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *group = GroupKey(entryKey, _entries[entryKey]);
        if (!groups[group]) groups[group] = [NSMutableArray array];
        [groups[group] addObject:_entries[entryKey]];
    }
    NSString *(^oldestPriorID)(NSArray<SZFriendsMergerEntry *> *, NSSet<NSString *> *) =
        ^NSString *(NSArray<SZFriendsMergerEntry *> *members, NSSet<NSString *> *claimed) {
            NSString *best = nil;
            for (SZFriendsMergerEntry *member in members) {
                NSString *prior = member.candidateID;
                if (!prior || [claimed containsObject:prior] || !self->_sequenceByCandidateID[prior]) continue;
                if (!best || [self->_sequenceByCandidateID[prior] compare:self->_sequenceByCandidateID[best]] ==
                                 NSOrderedAscending) {
                    best = prior;
                }
            }
            return best;
        };
    // Older groups claim their ids first, so when two candidates merge the older id survives, and when one splits
    // the part that keeps the older id is deterministic.
    NSArray<NSString *> *order =
        [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSString *idA = oldestPriorID(groups[a], [NSSet set]);
            NSString *idB = oldestPriorID(groups[b], [NSSet set]);
            if (idA && idB && ![idA isEqualToString:idB]) {
                return [self->_sequenceByCandidateID[idA] compare:self->_sequenceByCandidateID[idB]];
            }
            if ((idA != nil) != (idB != nil)) return idA ? NSOrderedAscending : NSOrderedDescending;
            return [a compare:b];
        }];
    NSMutableSet<NSString *> *claimed = [NSMutableSet set];
    NSMutableArray<SZFriendsCandidate *> *candidates = [NSMutableArray array];
    NSMutableArray<SZFriendsCandidate *> *unmatched = [NSMutableArray array];
    NSMutableString *signature = [NSMutableString string];
    for (NSString *group in order) {
        NSArray<SZFriendsMergerEntry *> *members = [groups[group]
            sortedArrayUsingComparator:^NSComparisonResult(SZFriendsMergerEntry *a, SZFriendsMergerEntry *b) {
                return CompareSightings(a, b);
            }];
        NSString *candidateID = oldestPriorID(members, claimed) ?: [self newCandidateID];
        [claimed addObject:candidateID];
        NSMutableArray<SZFriendsSighting *> *sightings = [NSMutableArray array];
        NSData *identityKey = nil;
        BOOL allPublic = YES;
        for (SZFriendsMergerEntry *member in members) {
            member.candidateID = candidateID;
            [sightings addObject:member.sighting];
            if (!identityKey) identityKey = member.identityKey;
            allPublic = allPublic && member.sighting.isPublic;
        }
        BOOL isConversation = [group hasPrefix:@"c:"];
        NSString *conversationID = isConversation ? [group substringFromIndex:2] : nil;
        // Public means a public entry of someone not in the list: friends are dialed with IK whatever they show.
        SZFriendsCandidate *candidate = [[SZFriendsCandidate alloc] initWithID:candidateID
                                                                conversationID:conversationID
                                                                      isPublic:!isConversation && allPublic
                                                                     sightings:sightings
                                                                   identityKey:identityKey];
        BOOL hidden = [group hasPrefix:@"t:"] || [group hasPrefix:@"u:"];
        [(hidden ? unmatched : candidates) addObject:candidate];
        [signature appendFormat:@"%@=%@%@[", group, candidateID, identityKey ? HexString(identityKey) : @""];
        for (SZFriendsSighting *s in sightings) {
            [signature appendFormat:@"%ld/%@/%ld/%@/%d/", (long)s.method, s.endpointID, (long)s.route,
                                    s.presenceTag ? HexString(s.presenceTag) : @"", s.isPublic];
            for (NSData *tag in s.callbackTags) [signature appendString:HexString(tag)];
        }
        [signature appendString:@"];"];
    }
    // Forget ids no group holds any more, so the table cannot grow without bound.
    for (NSString *candidateID in _sequenceByCandidateID.allKeys) {
        if (![claimed containsObject:candidateID]) [_sequenceByCandidateID removeObjectForKey:candidateID];
    }
    NSComparator bySequence = ^NSComparisonResult(SZFriendsCandidate *a, SZFriendsCandidate *b) {
        return [self->_sequenceByCandidateID[a.candidateID] compare:self->_sequenceByCandidateID[b.candidateID]];
    };
    _candidates = [candidates sortedArrayUsingComparator:bySequence];
    _unmatchedDevices = [unmatched sortedArrayUsingComparator:bySequence];
    if (![signature isEqualToString:_signature]) {
        _signature = [signature copy];
        _generation++;
    }
}

@end
