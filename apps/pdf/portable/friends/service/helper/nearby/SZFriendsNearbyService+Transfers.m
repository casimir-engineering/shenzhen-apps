// Accepted files on a live session: windowed chunks, durable progress, the final digest, and resuming on any new
// session from the recipient's durable offset (ADR 0001 § Files, § Resume and route migration; ADR 0003 § Durable
// progress).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

// Received bytes become durable in batches (ADR 0003); when chunks pause (a full window over Bluetooth, the end of
// a file) this makes them durable anyway, so the sender's window reopens.
static const NSTimeInterval SZFriendsProgressFlushDelay = 0.5;

@implementation SZFriendsNearbyService (Transfers)

#pragma mark - Receiving

- (void)startTransfersOnLink:(SZFriendsPeerLink *)link {
    NSString *conversationID = link.conversationID;
    if (!link.live || !link.adopted || link.closed || conversationID == nil) return;
    NSArray<SZFriendsTransferRecord *> *unfinished =
        [self.services.transfers unfinishedIncomingTransfersForConversation:conversationID];
    BOOL flushed = NO;
    for (SZFriendsTransferRecord *__strong record in unfinished) {
        if (link.receivers[record.transferID] != nil) continue;
        NSData *wire = SZFriendsLinkBytesFromHex(record.transferID);
        if (wire == nil) continue;
        if (!flushed) {
            // The store appends only at its written offset; making it durable first means the offset we announce is
            // exactly where the next chunk must land, whatever an earlier session left half-written.
            [self.services.transfers flushProgressWithError:NULL];
            flushed = YES;
            record = [self.services.transfers transferWithID:record.transferID] ?: record;
        }
        SZFriendsChunkReceiver *receiver = [[SZFriendsChunkReceiver alloc] initWithOfferID:wire
                                                                                      size:record.size
                                                                            verifiedOffset:record.verifiedBytes
                                                                                     route:link.raceRoute];
        if (receiver == nil) continue;
        link.receivers[record.transferID] = receiver;
        [link.endedTransfers removeObject:record.transferID];
        link.rateStart[record.transferID] = @[ @(record.verifiedBytes), [NSDate date] ];
        [link.channel sendFrame:[receiver resumeProgressFrame]];
    }
}

- (BOOL)refuseUnsolicitedOnLink:(SZFriendsPeerLink *)link transfer:(NSString *)transferID {
    // Chunks already on the wire when a transfer stopped, or when the link lost the race, are simply late.
    if (link.superseded || [link.endedTransfers containsObject:transferID]) return NO;
    // ADR 0001: no chunk moves before acceptance; one that does closes the session.
    SZFriendsHelperLog(@"unsolicited chunk: closing the session");
    [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
    return YES;
}

- (void)endTransfer:(NSString *)transferID onLink:(SZFriendsPeerLink *)link {
    [link.receivers removeObjectForKey:transferID];
    [link.senders removeObjectForKey:transferID];
    [link.sources[transferID] closeFile];
    [link.sources removeObjectForKey:transferID];
    [link.doneSent removeObject:transferID];
    [link.rateStart removeObjectForKey:transferID];
    [link.endedTransfers addObject:transferID];
}

- (void)link:(SZFriendsPeerLink *)link receivedChunkFrame:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    uint64_t offset = 0;
    if (wire == nil || ![frame getUInt64:&offset forTag:SZFriendsFieldOffset]) return;
    NSString *transferID = SZFriendsLinkHex(wire);
    SZFriendsChunkReceiver *receiver = link.receivers[transferID];
    if (receiver == nil) {
        [self refuseUnsolicitedOnLink:link transfer:transferID];
        return;
    }
    NSError *error = nil;
    NSData *data = [receiver acceptChunkFrame:frame error:&error];
    if (data == nil) {
        SZFriendsHelperLog(@"a chunk out of place: closing the session");
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    if (![self.services.transfers appendChunk:data atOffset:offset toTransfer:transferID
                             fromConversation:link.conversationID error:&error]) {
        // Cancelled, declined or deleted meanwhile, or the disk is full: this link stops carrying it. A download
        // still Receiving resumes from its durable offset on the next session.
        SZFriendsHelperLog(@"a chunk was not stored: %@", error.localizedDescription);
        [self endTransfer:transferID onLink:link];
        [self changed];
        return;
    }
    [self reportProgressOnLink:link transfer:transferID];
    [self armProgressFlushOnLink:link];
    [self progressChanged];
}

- (void)reportProgressOnLink:(SZFriendsPeerLink *)link transfer:(NSString *)transferID {
    SZFriendsChunkReceiver *receiver = link.receivers[transferID];
    if (receiver == nil) return;
    // PROGRESS reports only what the store committed after F_FULLFSYNC (ADR 0003): the sender's window and every
    // later resume rest on it.
    uint64_t durable = [self.services.transfers transferWithID:transferID].verifiedBytes;
    if (durable <= receiver.reportedOffset) return;
    SZFriendsFrame *progress = [receiver progressFrameForDurableOffset:durable];
    if (progress != nil) [link.channel sendFrame:progress];
}

- (void)armProgressFlushOnLink:(SZFriendsPeerLink *)link {
    if (link.progressTimer != nil) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_source_set_event_handler(timer, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil) return;
        dispatch_source_cancel(strongLink.progressTimer);
        strongLink.progressTimer = nil;
        [weakSelf flushProgressOnLink:strongLink];
    });
    int64_t delay = (int64_t)(SZFriendsProgressFlushDelay * NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delay), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 20);
    link.progressTimer = timer;
    dispatch_resume(timer);
}

- (void)flushProgressOnLink:(SZFriendsPeerLink *)link {
    if (link.receivers.count == 0) return;
    [self.services.transfers flushProgressWithError:NULL];
    if (link.closed || link.superseded) return;
    for (NSString *transferID in link.receivers.allKeys) [self reportProgressOnLink:link transfer:transferID];
    [self progressChanged];
}

- (void)link:(SZFriendsPeerLink *)link receivedDoneFrame:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire == nil) return;
    NSString *transferID = SZFriendsLinkHex(wire);
    SZFriendsChunkReceiver *receiver = link.receivers[transferID];
    if (receiver == nil) {
        [self refuseUnsolicitedOnLink:link transfer:transferID];
        return;
    }
    NSError *error = nil;
    NSData *digest = [receiver acceptDoneFrame:frame error:&error];
    if (digest == nil) {
        SZFriendsHelperLog(@"an early DONE: closing the session");
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    [self endTransfer:transferID onLink:link];
    // Published into received/ only when the whole-file digest matches the offer; then, and only then, the ACK.
    // A mismatch deletes the file and fails the transfer (Try again starts over); the sender hears nothing and
    // resends from zero once the person retries.
    if ([self.services.transfers finishTransfer:transferID finalDigest:digest fromConversation:link.conversationID
                                          error:&error]) {
        [self sendAckForID:wire onLink:link];
        // The file is what it claimed to be: our own preview of it now replaces the sender's (+Thumbnails).
        [self makeLocalThumbnailForReceivedTransfer:transferID];
        [self.services.notifier noteTransferReceived:transferID]; // a file accepted automatically, now here
    } else {
        SZFriendsHelperLog(@"a received file did not verify: %@", error.localizedDescription);
    }
    [self changed];
}

#pragma mark - Sending

- (void)link:(SZFriendsPeerLink *)link receivedProgressFrame:(SZFriendsFrame *)frame {
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    uint64_t offset = 0;
    if (wire == nil || ![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || link.superseded) return;
    NSString *transferID = SZFriendsLinkHex(wire);
    NSError *error = nil;
    SZFriendsChunkSender *sender = link.senders[transferID];
    if (sender != nil) {
        if (![sender handleProgressFrame:frame error:&error]) {
            SZFriendsHelperLog(@"a PROGRESS out of place: closing the session");
            [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
            return;
        }
        [self progressChanged];
        [self pumpLink:link];
        return;
    }
    if ([link.endedTransfers containsObject:transferID] && link.senders[transferID] == nil &&
        [self.services.transfers transferWithID:transferID].state != SZFriendsTransferStateSending) {
        return;
    }
    // The first PROGRESS for an accepted offer on this link: continue from the recipient's durable offset, and
    // only for our own offer to this friend, still accepted, whose snapshot still hashes to the offered digest
    // (the store checks all of that).
    SZFriendsTransferRecord *transfer =
        link.conversationID ? [self.services.transfers transferWithID:transferID inConversation:link.conversationID]
                            : nil;
    if (transfer == nil || !transfer.outgoing || transfer.state != SZFriendsTransferStateSending ||
        transfer.stagedPath == nil) {
        return;
    }
    if (![self.services.transfers peerAnsweredTransfer:transferID accepted:YES offset:offset
                                      fromConversation:link.conversationID error:&error]) {
        SZFriendsHelperLog(@"a transfer cannot resume: %@", error.localizedDescription);
        [self changed];
        return;
    }
    NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:transfer.stagedPath];
    sender = [[SZFriendsChunkSender alloc] initWithOfferID:wire size:transfer.size resumeOffset:offset
                                                     route:link.raceRoute];
    if (source == nil || sender == nil) {
        [self.services.transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
        [self changed];
        return;
    }
    [link.endedTransfers removeObject:transferID];
    link.senders[transferID] = sender;
    link.sources[transferID] = source;
    link.rateStart[transferID] = @[ @(offset), [NSDate date] ];
    if (offset > 0) {
        SZFriendsHelperLog(@"transfer %@ resumes at byte %llu", [transferID substringToIndex:8],
                           (unsigned long long)offset);
    }
    [self pumpLink:link];
}

// Chunks while the window has room. The channel lets messages overtake queued chunks, so a big file never holds up
// a conversation.
- (void)pumpLink:(SZFriendsPeerLink *)link {
    if (!link.live || link.closed || link.superseded || self.handingOver || self.shutDown) return;
    double rate = SZFriendsHelperTestHooks.chunkBytesPerSecond;
    for (NSString *transferID in link.senders.allKeys) {
        SZFriendsChunkSender *sender = link.senders[transferID];
        NSFileHandle *source = link.sources[transferID];
        uint64_t offset = 0;
        NSUInteger length = 0;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            if (rate > 0 && [self paceLink:link bytes:length rate:rate]) return;
            NSData *data = nil;
            @try {
                [source seekToFileOffset:offset];
                data = [source readDataOfLength:length];
            } @catch (NSException *exception) {
                data = nil;
            }
            if (data.length != length) {
                // The snapshot vanished under us: nothing true can be sent from it.
                [self.services.transfers failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing
                                                error:NULL];
                [self endTransfer:transferID onLink:link];
                [self changed];
                break;
            }
            SZFriendsFrame *chunk = [sender chunkFrameWithData:data];
            if (chunk == nil || ![link.channel sendFrame:chunk]) break;
            link.paceBytes += length;
        }
        if (sender.allSent && link.senders[transferID] != nil && ![link.doneSent containsObject:transferID]) {
            SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:transferID];
            NSData *wire = SZFriendsLinkBytesFromHex(transferID);
            if (transfer.contentDigest.length != 32 || wire == nil) continue;
            NSDictionary *fields = @{@(SZFriendsFieldID) : wire, @(SZFriendsFieldDigest) : transfer.contentDigest};
            if ([link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeDone fields:fields]]) {
                [link.doneSent addObject:transferID];
                [link expectAckForID:transferID token:[@"done:" stringByAppendingString:transferID]];
            }
        }
    }
}

// YES when this chunk would go faster than the test's cap: the pump runs again once it may.
- (BOOL)paceLink:(SZFriendsPeerLink *)link bytes:(NSUInteger)bytes rate:(double)rate {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (link.paceStart == 0) link.paceStart = now;
    double due = (double)(link.paceBytes + bytes) / rate - (now - link.paceStart);
    if (due <= 0) return NO;
    if (!link.pumpScheduled) {
        link.pumpScheduled = YES;
        __weak SZFriendsNearbyService *weakSelf = self;
        __weak SZFriendsPeerLink *weakLink = link;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due * NSEC_PER_SEC)), self.queue, ^{
            SZFriendsPeerLink *strongLink = weakLink;
            strongLink.pumpScheduled = NO;
            if (strongLink != nil) [weakSelf pumpLink:strongLink];
        });
    }
    return YES;
}

- (void)link:(SZFriendsPeerLink *)link transferAcknowledged:(NSString *)transferID {
    // Their Mac verified the digest and published the file: Delivered, and our private snapshot goes.
    if (link.conversationID != nil) {
        [self.services.transfers peerVerifiedTransfer:transferID fromConversation:link.conversationID error:NULL];
    }
    [self endTransfer:transferID onLink:link];
    [self changed];
}

#pragma mark - Stopping and state

- (void)stopTransfer:(NSString *)transferID {
    for (SZFriendsPeerLink *link in self.links) [self endTransfer:transferID onLink:link];
    [self changed];
}

- (BOOL)transfersInFlight {
    for (SZFriendsPeerLink *link in self.links) {
        if (link.closed) continue;
        for (SZFriendsChunkSender *sender in link.senders.allValues) {
            if (sender.sentOffset > sender.durableOffset) return YES;
        }
        for (SZFriendsChunkReceiver *receiver in link.receivers.allValues) {
            if (receiver.receivedOffset > receiver.reportedOffset) return YES;
        }
    }
    return NO;
}

@end
