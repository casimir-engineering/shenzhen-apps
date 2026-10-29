// Fast transfers on one session (SZFriendsBlockExchange.h).

#import "service/transfer/SZFriendsBlockExchange.h"

#import "service/transfer/SZFriendsBlockFlow.h"

// What one session keeps sent and not yet in a HAVE (one lane; the scheduler sizes this per lane with lanes), as the
// Rust helper's.
static const uint64_t SZFriendsBlockWindow = 16ull << 20;
static const uint64_t SZFriendsBlockWindowBluetooth = 2ull << 20;

static NSString *SZFriendsBlockHex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSData *_Nullable SZFriendsBlockBytes(NSString *hex) {
    if (hex.length != 32) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:16];
    uint8_t *bytes = out.mutableBytes;
    for (NSUInteger i = 0; i < 16; i++) {
        unichar high = [hex characterAtIndex:2 * i], low = [hex characterAtIndex:2 * i + 1];
        if (!isxdigit(high) || !isxdigit(low)) return nil;
        bytes[i] = (uint8_t)(digittoint(high) << 4 | digittoint(low));
    }
    return out;
}

// One of our files going by blocks on this session.
@interface SZFriendsBlockSend : NSObject
@property(nonatomic, strong) SZFriendsBlockServe *serve;
@property(nonatomic, strong) SZFriendsTransferRecord *record;
@property(nonatomic) BOOL resumed; // began on an earlier session
@end

@implementation SZFriendsBlockSend
@end

@implementation SZFriendsBlockExchange {
    SZFriendsTransfers *_transfers;
    NSString *_conversationID;
    SZFriendsRouteMethod _route;
    BOOL (^_send)(SZFriendsFrame *);
    NSMutableDictionary<NSString *, SZFriendsBlockSend *> *_senders;
    NSMutableSet<NSString *> *_receivers;
}

- (instancetype)initWithTransfers:(SZFriendsTransfers *)transfers
                   conversationID:(NSString *)conversationID
                            route:(SZFriendsRouteMethod)route
                             send:(BOOL (^)(SZFriendsFrame *))send {
    if ((self = [super init])) {
        _transfers = transfers;
        _conversationID = [conversationID copy];
        _route = route;
        _send = [send copy];
        _senders = [NSMutableDictionary dictionary];
        _receivers = [NSMutableSet set];
    }
    return self;
}

- (void)changed {
    if (self.onChanged) self.onChanged();
}

- (NSSet<NSString *> *)receiving {
    return [_receivers copy];
}

- (NSSet<NSString *> *)sending {
    return [NSSet setWithArray:_senders.allKeys];
}

- (BOOL)carriesTransfers {
    return _senders.count > 0 || _receivers.count > 0;
}

- (BOOL)awaitingPeer {
    if (_receivers.count > 0) return YES; // blocks are wanted: their parts are due
    for (SZFriendsBlockSend *send in _senders.allValues) {
        if (send.serve.awaitingHave) return YES;
    }
    return NO;
}

#pragma mark - Offers and replies

+ (void)addTreeOfTransfer:(SZFriendsTransferRecord *)record
                 toFields:(NSMutableDictionary<NSNumber *, NSData *> *)fields
                transfers:(SZFriendsTransfers *)transfers {
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *leaves = nil;
    if (![transfers senderTreeForTransfer:record compute:NO geometry:&geometry root:&root leaves:&leaves]) return;
    fields[@(SZFriendsFieldTreeRoot)] = root;
    fields[@(SZFriendsFieldBlockShift)] = [NSData dataWithBytes:&geometry.shift length:1];
}

- (void)noteOffer:(SZFriendsFrame *)offer transferID:(NSString *)transferID {
    SZFriendsBlockGeometry geometry;
    NSData *root = nil;
    if (SZFriendsOfferedTree(offer, &geometry, &root)) {
        [_transfers recordOfferedTree:transferID conversation:_conversationID geometry:geometry root:root];
    }
}

+ (void)addBlocksToReply:(NSMutableDictionary<NSNumber *, NSData *> *)fields
             forTransfer:(NSString *)transferID
               transfers:(SZFriendsTransfers *)transfers {
    if (![transfers hasOfferedTree:transferID]) return;
    uint8_t one = 1;
    fields[@(SZFriendsFieldBlocks)] = [NSData dataWithBytes:&one length:1];
}

#pragma mark - Receiving

- (BOOL)resumeIncoming:(SZFriendsTransferRecord *)record {
    NSString *transferID = record.transferID;
    if (![_transfers hasOfferedTree:transferID]) return NO;
    NSError *error = nil;
    if (![_transfers beginBlocks:transferID conversation:_conversationID error:&error]) {
        // Taken by CHUNK after all: the CHUNK flow resumes from the prefix, and the map would lie.
        [_transfers dropBlocks:transferID];
        return NO;
    }
    [_receivers addObject:transferID];
    [_transfers claimBlocks:transferID forSession:self];
    NSData *wire = SZFriendsBlockBytes(transferID);
    NSData *missing = [_transfers blocksMissing:transferID];
    for (SZFriendsFrame *frame in SZFriendsWantFrames(wire, missing)) _send(frame);
    // Every block arrived before the last session ended: the check and the ACK are all that is left.
    if (missing.length == 0) [self progressed:transferID];
    return YES;
}

// After blocks were written or made durable: HAVE for what changed, and once every block is durable, the check
// before saving and the ACK.
- (void)progressed:(NSString *)transferID {
    NSData *complete = nil, *durable = nil;
    [_transfers takeBlockHave:transferID complete:&complete durable:&durable];
    NSData *wire = SZFriendsBlockBytes(transferID);
    for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, complete, durable)) _send(frame);
    if (complete.length || durable.length) [self changed];
    if (![_transfers blocksAllDurable:transferID]) return;
    [_receivers removeObject:transferID];
    NSError *error = nil;
    if ([_transfers finishBlockTransfer:transferID fromConversation:_conversationID error:&error]) {
        _send([SZFriendsFrame frameWithType:SZFriendsFrameTypeAck fields:@{@(SZFriendsFieldID) : wire}]);
        if (self.onReceived) self.onReceived(transferID);
    } else {
        NSLog(@"Friends: a file received by blocks did not check: %@", error.localizedDescription);
    }
    [self changed];
}

- (BOOL)hashes:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *index = [frame dataForTag:SZFriendsFieldIndex], *hashes = [frame dataForTag:SZFriendsFieldHashes];
    const uint8_t *bytes = index.bytes;
    uint32_t first = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    NSError *error = nil;
    if ([_transfers acceptBlockHashes:hashes index:first forTransfer:transferID fromConversation:_conversationID
                                error:&error]) {
        if (![_receivers containsObject:transferID]) {
            [_receivers addObject:transferID];
            [_transfers claimBlocks:transferID forSession:self];
        }
        [self progressed:transferID];
        return YES;
    }
    return error.code == SZFriendsStoreErrorStale; // cancelled or finished meanwhile
}

- (BOOL)part:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    // Compressed parts are capability bit 2, which this build does not set.
    if ([frame dataForTag:SZFriendsFieldCodec] != nil) return NO;
    uint64_t offset = 0;
    NSData *data = [frame dataForTag:SZFriendsFieldData];
    if (![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || data == nil) return NO;
    if (![_receivers containsObject:transferID]) {
        // ADR 0018 § 3: late for a transfer that just ended here (a block sent on two lanes, a part already on its
        // way when the file was complete or cancelled); unsolicited otherwise.
        SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
        return record != nil && !record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    uint32_t block = 0;
    NSError *error = nil;
    switch ([_transfers acceptBlockPart:data atOffset:offset forTransfer:transferID fromConversation:_conversationID
                                  block:&block error:&error]) {
    case SZFriendsBlockPartRefused: return NO;
    case SZFriendsBlockPartPending:
    case SZFriendsBlockPartLate: return YES;
    case SZFriendsBlockPartStale: [_receivers removeObject:transferID]; return YES;
    case SZFriendsBlockPartCorrupt: {
        // Fetched again alone; the file does not restart.
        for (SZFriendsFrame *want in SZFriendsWantFrames(SZFriendsBlockBytes(transferID), SZFriendsRange(block, 1))) {
            _send(want);
        }
        return YES;
    }
    case SZFriendsBlockPartWritten:
        [self progressed:transferID];
        if (_transfers.blocksPending && self.onFlushNeeded) self.onFlushNeeded();
        return YES;
    }
    return NO;
}

#pragma mark - Sending

- (nullable SZFriendsBlockSend *)startSending:(NSString *)transferID {
    SZFriendsBlockSend *send = _senders[transferID];
    if (send) return send;
    BOOL first = NO;
    NSError *error = nil;
    SZFriendsTransferRecord *record = [_transfers peerTookBlocks:transferID fromConversation:_conversationID
                                                           first:&first error:&error];
    if (record == nil) {
        if (error.code == SZFriendsStoreErrorFileMissing) [self changed];
        return nil;
    }
    SZFriendsBlockGeometry geometry;
    NSData *root = nil, *leaves = nil;
    if (![_transfers senderTreeForTransfer:record compute:YES geometry:&geometry root:&root leaves:&leaves]) {
        [_transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
        [self changed];
        return nil;
    }
    BOOL bluetooth = _route == SZFriendsRouteMethodBluetooth;
    send = [[SZFriendsBlockSend alloc] init];
    send.record = record;
    send.serve = [[SZFriendsBlockServe alloc] initWithTransferID:SZFriendsBlockBytes(transferID)
                                                        geometry:geometry
                                                          leaves:leaves
                                                       partBytes:SZFriendsChunkBytesForRoute(_route)
                                                     windowBytes:bluetooth ? SZFriendsBlockWindowBluetooth
                                                                           : SZFriendsBlockWindow];
    if (first) [send.serve wantAll];
    send.resumed = !first;
    for (SZFriendsFrame *frame in send.serve.hashesFrames) _send(frame);
    _senders[transferID] = send;
    if (self.onSending) self.onSending(transferID);
    [self changed];
    return send;
}

- (BOOL)offerTakenByBlocks:(NSString *)transferID {
    if ([self startSending:transferID] == nil) return NO;
    [self pump];
    return YES;
}

- (BOOL)want:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *ranges = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
    if (ranges.length == 0) return NO;
    // A WANT only for an offer this side made to that person and they accepted (§ 8).
    SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
    if (record == nil || !record.outgoing || ![record.conversationID isEqualToString:_conversationID] ||
        (record.state != SZFriendsTransferStateSending && record.state != SZFriendsTransferStateOffered)) {
        // Late for a transfer of ours that ended meanwhile (delivered, cancelled): nothing to send.
        return record != nil && record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    SZFriendsBlockSend *send = [self startSending:transferID];
    if (send == nil) return YES; // the transfer failed here (snapshot gone); it says so itself
    if (![send.serve want:ranges]) return NO;
    if (self.onWanted) {
        uint64_t offset = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(send.serve.geometry, ((const uint32_t *)ranges.bytes)[0], &offset, &length);
        self.onWanted(transferID, offset, send.resumed);
    }
    [self pump];
    return YES;
}

- (BOOL)have:(SZFriendsFrame *)frame transfer:(NSString *)transferID {
    NSData *complete = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
    if (complete == nil || SZFriendsFrameRanges(frame, SZFriendsFieldDurable) == nil) return NO;
    SZFriendsBlockSend *send = _senders[transferID];
    if (send == nil) {
        // ADR 0018 § 3: a HAVE for one of our transfers that ended here meanwhile is late; for anything else it is
        // unsolicited.
        SZFriendsTransferRecord *record = [_transfers transferWithID:transferID];
        return record != nil && record.outgoing && [record.conversationID isEqualToString:_conversationID];
    }
    if (![send.serve have:complete]) return NO;
    [self changed];
    [self pump];
    return YES;
}

- (BOOL)handleFrame:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire.length != 16) return NO;
    NSString *transferID = SZFriendsBlockHex(wire);
    switch (frame.type) {
    case SZFriendsFrameTypeHashes: return [self hashes:frame transfer:transferID];
    case SZFriendsFrameTypeWant: return [self want:frame transfer:transferID];
    case SZFriendsFrameTypePart: return [self part:frame transfer:transferID];
    case SZFriendsFrameTypeHave: return [self have:frame transfer:transferID];
    default: return NO;
    }
}

- (void)pump {
    for (NSString *transferID in _senders.allKeys) {
        SZFriendsBlockSend *send = _senders[transferID];
        while (send != nil) {
            NSUInteger length = send.serve.nextPartLength;
            if (length > 0 && self.pace && self.pace(length)) return;
            SZFriendsFrame *part = [send.serve nextPart];
            if (part != nil) {
                if (!_send(part)) return;
                continue;
            }
            uint32_t block = 0;
            if (![send.serve nextBlock:&block]) break;
            NSData *data = [_transfers readOutgoingBlock:block ofTransfer:send.record geometry:send.serve.geometry];
            if (data == nil || ![send.serve loadBlock:block data:data]) {
                // The snapshot changed or went: the transfer fails before a byte of the changed block leaves.
                [_senders removeObjectForKey:transferID];
                [_transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
                [self changed];
                break;
            }
            // An empty file's one block has no parts: it is sent once loaded.
            if (data.length == 0) [send.serve nextPart];
        }
    }
}

#pragma mark - Durability and endings

- (void)flushDue {
    for (NSString *transferID in [_transfers flushDueBlocks:NO]) {
        if ([_receivers containsObject:transferID]) [self progressed:transferID];
    }
    if (_transfers.blocksPending && self.onFlushNeeded) self.onFlushNeeded();
}

- (void)sessionEnded {
    [_transfers flushDueBlocks:YES];
    [_transfers blocksSessionEnded:_receivers.allObjects session:self];
    [_receivers removeAllObjects];
    [_senders removeAllObjects];
}

- (void)endTransfer:(NSString *)transferID {
    [_receivers removeObject:transferID];
    [_senders removeObjectForKey:transferID];
}

@end
