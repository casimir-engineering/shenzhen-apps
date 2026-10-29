// Getting a file again in the helper (ADR 0016; PROTOCOL.md § Getting a file again; service/sync/SZFriendsAgain.h).
//
// The person's side: Get again on a file a friend sent, which none of their computers holds any more, is kept in the
// store ("again/<transfer id>": 1 asked, 2 the friend no longer has it) and copied on the next session with that
// friend at session minor 3, nearby or online, into the folder received files go to. The friend's side: a session with
// someone it sent a file to may ask for it again, and gets it, unasked, only from this computer's own bytes of that
// very file, unchanged since it was sent, within a few checks an hour.

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/store/SZFriendsStoreSync.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/sync/SZFriendsSync.h"

static NSString *const SZFriendsAgainPrefix = @"again/";
static const uint16_t SZFriendsAgainMinor = 3;
static const NSUInteger SZFriendsAgainChecksPerHour = 20;

static NSString *SZFriendsAgainKey(NSString *transferID) {
    return [SZFriendsAgainPrefix stringByAppendingString:transferID];
}

@implementation SZFriendsNearbyService (Again)

#pragma mark - State

- (SZFriendsAgainState)againStateOfTransfer:(NSString *)transferID {
    id value = [self.services.store syncStateForKey:SZFriendsAgainKey(transferID)];
    NSInteger state = [value isKindOfClass:[NSNumber class]] ? [value integerValue] : 0;
    return state == SZFriendsAgainAsked || state == SZFriendsAgainGone ? (SZFriendsAgainState)state : SZFriendsAgainNone;
}

- (void)setAgainState:(SZFriendsAgainState)state ofTransfer:(NSString *)transferID {
    id value = state == SZFriendsAgainNone ? nil : @(state);
    [self.services.store setSyncState:value forKey:SZFriendsAgainKey(transferID) error:NULL];
}

- (BOOL)anotherComputerHoldsFile:(nullable SZFriendsSyncFileRecord *)file {
    if (file.holders.count == 0) return NO;
    NSArray<NSData *> *ours = [self activeSyncEngine].otherDeviceKeys ?: @[];
    for (NSData *holder in file.holders) {
        if ([ours containsObject:holder]) return YES;
    }
    return NO;
}

- (BOOL)againCopyingTransfer:(NSString *)transferID fraction:(double *)fraction {
    for (SZFriendsPeerLink *link in self.links) {
        if (link.closed || ![link.againExchange.copyingTransferID isEqualToString:transferID]) continue;
        if (fraction) *fraction = link.againExchange.copyingFraction;
        return YES;
    }
    return NO;
}

- (BOOL)againReachesConversation:(NSString *)conversationID {
    SZFriendsPeerLink *live = [self liveLinkForConversation:conversationID];
    return live != nil && live.channel.negotiatedMinor >= SZFriendsAgainMinor;
}

#pragma mark - The person's side

- (nullable NSString *)fetchFileFromFriend:(NSString *)transferID reason:(NSString *_Nullable *_Nullable)reason {
    SZFriendsStore *store = self.services.store;
    SZFriendsTransferRecord *row = [store transferRecordWithID:transferID];
    SZFriendsSyncFileRecord *record = [store syncFileWithID:transferID];
    NSString *conversationID = row.conversationID ?: record.conversationID;
    if (conversationID == nil || [store itemIDForTransfer:transferID inConversation:conversationID] == nil) {
        if (reason) *reason = @"again";
        return @"not_found";
    }
    BOOL incoming = row != nil ? !row.outgoing : !record.outgoing;
    SZFriendsTransferState state = row != nil ? row.state : record.state;
    SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
    BOOL friend = person.relation == SZFriendsRelationFriend && person.identityKey != nil &&
                  ![conversationID isEqualToString:SZFriendsYouConversationID];
    BOOL here = row != nil && SZFriendsSyncLocalPathOfTransfer(row) != nil;
    if (!incoming || state != SZFriendsTransferStateReceived || !friend || here ||
        [self anotherComputerHoldsFile:record]) {
        return @"not_allowed";
    }
    SZFriendsTransfers *transfers = self.services.transfers;
    uint64_t size = row != nil ? row.size : record.size;
    uint64_t free = transfers.freeBytesProvider ? [transfers freeBytesForReceiving] : UINT64_MAX;
    if (free < size) return @"disk_full";
    [self setAgainState:SZFriendsAgainAsked ofTransfer:transferID];
    SZFriendsPeerLink *live = [self liveLinkForConversation:conversationID];
    if (live != nil) [[self againExchangeForLink:live] pump];
    [self scheduleReconsider]; // the friend is dialed nearby, and reached online
    [self changed];
    return nil;
}

- (BOOL)cancelAgainOfFile:(NSString *)transferID {
    if ([self againStateOfTransfer:transferID] != SZFriendsAgainAsked) return NO;
    [self setAgainState:SZFriendsAgainNone ofTransfer:transferID];
    for (SZFriendsPeerLink *link in self.links.copy) [link.againExchange abandon:transferID];
    [self changed];
    return YES;
}

- (NSArray<SZFriendsAgainFile *> *)againFilesWantedInConversation:(NSString *)conversationID {
    SZFriendsStore *store = self.services.store;
    NSMutableArray<SZFriendsAgainFile *> *files = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDate *> *created = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, id> *states = [store syncStatesWithPrefix:SZFriendsAgainPrefix];
    for (NSString *key in states) {
        if (![states[key] isKindOfClass:[NSNumber class]] || [states[key] integerValue] != SZFriendsAgainAsked) continue;
        NSString *transferID = [key substringFromIndex:SZFriendsAgainPrefix.length];
        SZFriendsTransferRecord *row = [store transferRecordWithID:transferID];
        SZFriendsSyncFileRecord *record = row == nil ? [store syncFileWithID:transferID] : nil;
        if (![(row.conversationID ?: record.conversationID) isEqualToString:conversationID]) continue;
        SZFriendsAgainFile *file = [[SZFriendsAgainFile alloc] init];
        file.transferID = transferID;
        file.size = row != nil ? row.size : record.size;
        file.digest = row != nil ? row.contentDigest : record.contentDigest;
        created[transferID] = (row != nil ? row.createdAt : record.createdAt) ?: [NSDate distantPast];
        [files addObject:file];
    }
    [files sortUsingComparator:^NSComparisonResult(SZFriendsAgainFile *a, SZFriendsAgainFile *b) {
        NSComparisonResult order = [created[a.transferID] compare:created[b.transferID]];
        return order != NSOrderedSame ? order : [a.transferID compare:b.transferID];
    }];
    return files;
}

- (BOOL)hasAgainRequestsForConversation:(NSString *)conversationID {
    return [self againFilesWantedInConversation:conversationID].count > 0;
}

// A whole copy whose digest matched: published where received files go, and the history's file points at it.
- (void)adoptAgainCopy:(SZFriendsAgainFile *)file path:(NSString *)path {
    SZFriendsStore *store = self.services.store;
    SZFriendsTransferRecord *row = [store transferRecordWithID:file.transferID];
    SZFriendsSyncFileRecord *record = [store syncFileWithID:file.transferID];
    SZFriendsTransferRecord *transfer = [row copy];
    if (transfer == nil && record != nil) { // received on another of the person's computers, never here
        transfer = [[SZFriendsTransferRecord alloc] init];
        transfer.transferID = record.transferID;
        transfer.conversationID = record.conversationID;
        transfer.outgoing = NO;
        transfer.state = SZFriendsTransferStateReceived;
        transfer.fileName = record.fileName;
        transfer.uniformType = record.uniformType;
        transfer.size = record.size;
        transfer.contentDigest = record.contentDigest;
        transfer.createdAt = record.createdAt;
    }
    NSError *error = nil;
    NSString *stateDirectory = self.services.transfers.receivedDirectory.stringByDeletingLastPathComponent;
    NSString *destination = transfer ? SZFriendsPublishReceivedFile(path, SZFriendsSanitizedFileName(transfer.fileName),
                                                                    stateDirectory, nil, &error)
                                     : nil;
    if (destination == nil ||
        ![store insertCopiedTransfer:transfer path:destination source:SZFriendsReceivedSourceFriend error:&error]) {
        SZFriendsHelperLog(@"could not keep a file got again: %@", error.localizedDescription ?: @"no record");
        if (destination != nil) [NSFileManager.defaultManager removeItemAtPath:destination error:NULL];
        return;
    }
    [self setAgainState:SZFriendsAgainNone ofTransfer:file.transferID];
    [self makeThumbnailsForTransfers:@[ file.transferID ]];
    [self changed]; // and our other computers hear that this one holds it again
}

- (void)againFileNotThere:(NSString *)transferID {
    if ([self againStateOfTransfer:transferID] != SZFriendsAgainAsked) return;
    [self setAgainState:SZFriendsAgainGone ofTransfer:transferID];
    [self changed];
}

#pragma mark - Sessions

- (nullable SZFriendsAgainExchange *)againExchangeForLink:(SZFriendsPeerLink *)link {
    if (link.againExchange != nil) return link.againExchange;
    NSString *conversationID = link.conversationID;
    if (link.closed || link.ownDevice || conversationID == nil || link.channel.pattern == SZFriendsHandshakeNN ||
        link.channel.negotiatedMinor < SZFriendsAgainMinor) {
        return nil;
    }
    NSString *partial = [self.services.transfers.receivedDirectory stringByAppendingPathComponent:@".partial"];
    __weak SZFriendsPeerLink *weakLink = link;
    __weak SZFriendsNearbyService *weakSelf = self;
    SZFriendsAgainExchange *exchange = [[SZFriendsAgainExchange alloc]
        initWithPartialDirectory:partial
                            send:^(NSData *message) {
                                SZFriendsPeerLink *strongLink = weakLink;
                                if (strongLink == nil || strongLink.closed) return;
                                [strongLink.channel sendFrame:[SZFriendsFrame
                                                                  frameWithType:SZFriendsFrameTypeAgain
                                                                         fields:@{@(SZFriendsFieldAgain) : message}]];
                            }];
    exchange.wanted = ^NSArray<SZFriendsAgainFile *> * {
        return [weakSelf againFilesWantedInConversation:conversationID] ?: @[];
    };
    exchange.arrived = ^(SZFriendsAgainFile *file, NSString *path) { [weakSelf adoptAgainCopy:file path:path]; };
    exchange.notThere = ^(NSString *transferID) { [weakSelf againFileNotThere:transferID]; };
    exchange.noRoom = ^(NSString *transferID) {
        [weakSelf setAgainState:SZFriendsAgainNone ofTransfer:transferID];
        [weakSelf changed];
    };
    exchange.servePath = ^NSString *_Nullable(NSString *transferID, uint64_t *size, SZFriendsAgainAnswer *answer) {
        return [weakSelf againPathToServe:transferID conversation:conversationID size:size answer:answer];
    };
    // Our copies by blocks on a fast session (ADR 0018 § 4), by offset otherwise; their HAVEs go on this session.
    exchange.fast = link.channel.fastTransfers;
    exchange.sendFrame = ^(SZFriendsFrame *frame) {
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink != nil && !strongLink.closed) [strongLink.channel sendFrame:frame];
    };
    // A copy by blocks (AGAIN 4, ADR 0018 § 4): the same checks, then the file's tree and the blocks asked for.
    __weak SZFriendsAgainExchange *weakExchange = exchange;
    exchange.wantBlocks = ^(NSString *transferID, uint8_t shift, NSData *ranges) {
        SZFriendsAgainExchange *strongExchange = weakExchange;
        SZFriendsPeerLink *strongLink = weakLink;
        uint64_t size = 0;
        NSString *path = [strongExchange beginServingBlocks:transferID size:&size];
        if (path == nil || strongLink == nil) return;
        if (![weakSelf serveCopyOnLink:strongLink transfer:transferID path:path size:size shift:shift ranges:ranges
                                  sync:NO]) {
            [strongExchange sendNone:transferID reason:SZFriendsAgainAnswerNotHere];
        }
    };
    link.againExchange = exchange;
    return exchange;
}

- (void)startAgainOnLink:(SZFriendsPeerLink *)link {
    [[self againExchangeForLink:link] pump];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedAgainFrame:(SZFriendsFrame *)frame {
    if (person.relation != SZFriendsRelationFriend) return; // only friends are given anything, or asked
    SZFriendsAgainExchange *exchange = [self againExchangeForLink:link];
    NSData *message = [frame dataForTag:SZFriendsFieldAgain];
    if (exchange == nil || message == nil) return;
    NSString *before = exchange.copyingTransferID;
    if (![exchange receiveMessage:message]) {
        SZFriendsHelperLog(@"an again message that does not decode");
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    if (before != nil || exchange.copyingTransferID != nil) [self progressChanged];
}

#pragma mark - The friend's side

// What may be given to the person this session is with: a file this computer sent them and still has, unchanged.
- (nullable NSString *)againPathToServe:(NSString *)transferID
                           conversation:(NSString *)conversationID
                                   size:(uint64_t *)size
                                 answer:(SZFriendsAgainAnswer *)answer {
    *answer = SZFriendsAgainAnswerNotHere;
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID
                                                                  inConversation:conversationID];
    if (person.relation != SZFriendsRelationFriend || transfer == nil || !transfer.outgoing ||
        transfer.state != SZFriendsTransferStateDelivered) {
        return nil;
    }
    NSString *path = SZFriendsSyncLocalPathOfTransfer(transfer);
    if (path == nil) {
        // Another of this person's computers may have it: they ask again later rather than hear it is gone.
        if ([self anotherComputerHoldsFile:[store syncFileWithID:transferID]]) *answer = SZFriendsAgainAnswerNotNow;
        return nil;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSString *checked = [NSString stringWithFormat:@"%@|%llu|%lld", path, attributes.fileSize,
                                                   SZFriendsFileModifiedNs(path)];
    if (self.againVerified == nil) self.againVerified = [NSMutableDictionary dictionary];
    if (![self.againVerified[transferID] isEqualToString:checked]) {
        if (self.againChecks == nil) self.againChecks = [NSMutableDictionary dictionary];
        NSMutableArray<NSDate *> *checks = self.againChecks[conversationID] ?: [NSMutableArray array];
        self.againChecks[conversationID] = checks;
        NSDate *hourAgo = [NSDate dateWithTimeIntervalSinceNow:-3600];
        [checks filterUsingPredicate:[NSPredicate predicateWithFormat:@"self > %@", hourAgo]];
        if (checks.count >= SZFriendsAgainChecksPerHour) {
            *answer = SZFriendsAgainAnswerNotNow;
            return nil;
        }
        [checks addObject:[NSDate date]];
        if (!SZFriendsFileHasDigest(path, transfer.size, transfer.contentDigest)) return nil; // changed: not that file
        self.againVerified[transferID] = checked;
    }
    *size = transfer.size;
    return path;
}

@end
