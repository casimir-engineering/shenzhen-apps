// The Objective-C interop peer's sessions: events out, Add by ID answers, and files through the helper's own store,
// as the nearby service moves them (service/helper/nearby/SZFriendsNearbyService+Transfers.m): an offer acknowledged
// and accepted, chunks through the window, PROGRESS from the store's durable count (flushed after a pause), DONE
// checked and acknowledged, and resume from the recipient's PROGRESS on every new session.

#import "SZFSessionPeer.h"

#import "service/session/SZFriendsSecureChannelInternal.h"

static NSString *const SZFPatternNames[] = {@"XX", @"IK", @"NN"};
// As the helper does: when chunks pause, received bytes are made durable anyway so the sender's window reopens.
static const NSTimeInterval SZFProgressFlushDelay = 0.5;

static SZFriendsFrame *SZFIDFrame(SZFriendsFrameType type, NSData *offerID, NSDictionary *more) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:more ?: @{}];
    fields[@(SZFriendsFieldID)] = offerID;
    return [SZFriendsFrame frameWithType:type fields:fields];
}

// As the helper does (ADR 0018 § 7): PING while the session carries a transfer, and close it after the silence limit
// while the other side owes PROGRESS or the rest of a file.
static void SZFUpdateLiveness(SZFPeerSession *session) {
    BOOL keepalive = NO, watch = NO;
    SZFriendsTransferLiveness(session.senders.allValues, session.receivers.allValues, &keepalive, &watch);
    keepalive |= session.blocks.carriesTransfers;
    watch |= session.blocks.awaitingPeer;
    [session.channel setLivenessKeepalive:keepalive watch:watch];
}

@implementation SZFPeer (Flows)

- (void)attachChannel:(SZFriendsSecureChannel *)channel toSession:(SZFPeerSession *)session {
    session.channel = channel;
    self.sessions[@(session.sessionID)] = session;
    __weak SZFPeer *weakSelf = self;
    __weak SZFPeerSession *weakSession = session;
    channel.onEstablished = ^{ [weakSelf establishedSession:weakSession]; };
    channel.onFrame = ^(SZFriendsFrame *frame) { [weakSelf session:weakSession receivedFrame:frame]; };
    channel.onClose = ^(NSError *error) {
        SZFPeer *strongSelf = weakSelf;
        SZFPeerSession *strongSession = weakSession;
        if (strongSelf == nil || strongSession == nil) return;
        [strongSession.laneHead.blocks laneDown:strongSession.sessionID];
        [strongSelf devicesClosed:strongSession];
        [strongSelf.transfers flushProgressWithError:NULL];
        if (![strongSelf handOverGroupOf:strongSession]) [strongSession.blocks sessionEnded];
        for (NSFileHandle *source in strongSession.sources.allValues) [source closeFile];
        NSNumber *reason = error.userInfo[SZFriendsSessionCloseReasonKey];
        SZFriendsSecureChannel *closing = strongSession.channel;
        [strongSelf emit:@{@"event" : @"closed", @"session" : @(strongSession.sessionID), @"error" : @(error.code),
                           @"reason" : reason ?: [NSNull null],
                           @"rekeys" : @[ @(closing.rekeysSent), @(closing.rekeysReceived) ]}];
        [strongSelf.sessions removeObjectForKey:@(strongSession.sessionID)];
    };
}

// The first session of a group closed while lanes live (ADR 0018 § 6: the group goes on), as the Rust peer: the lowest
// live lane takes over its conversation and its files by blocks, and the other lanes are its lanes now.
- (BOOL)handOverGroupOf:(SZFPeerSession *)old {
    SZFriendsBlockExchange *blocks = old.blocks;
    if (blocks.group == nil || [blocks laneDown:blocks.controlLane]) return NO;
    SZFPeerSession *head = self.sessions[@(blocks.controlLane)];
    if (head == nil) return NO;
    for (SZFPeerSession *lane in self.sessions.allValues) {
        if (lane.laneHead == old) lane.laneHead = head;
    }
    head.laneHead = nil;
    head.conversationID = old.conversationID;
    head.blocks = blocks;
    old.blocks = nil;
    [self wireBlocks:blocks toSession:head];
    SZFUpdateLiveness(head);
    return YES;
}

// A lane went live: ours joins its head's group, theirs is admitted by its token or refused (ADR 0018 § 6). YES when
// the session is a lane (or was refused as one).
- (BOOL)laneEstablished:(SZFPeerSession *)session event:(NSDictionary *)event {
    SZFriendsSecureChannel *channel = session.channel;
    SZFPeerSession *head = session.laneHead;
    if (head == nil && !channel.isInitiator && channel.presentedLane != nil) {
        for (SZFPeerSession *candidate in self.sessions.allValues) {
            if (candidate == session || candidate.laneHead != nil || candidate.blocks == nil ||
                ![candidate.channel.remoteIdentityKey isEqualToData:channel.remoteIdentityKey]) {
                continue;
            }
            if ([candidate.blocks admitLane:session.sessionID token:channel.presentedLane
                                      route:channel.initiatorRoute] == SZFriendsLaneAdmitted) {
                head = candidate;
                session.laneHead = head;
                break;
            }
        }
        if (head == nil || !channel.fastTransfers) {
            [channel closeWithReason:SZFriendsCloseReasonLaneRefused];
            return YES;
        }
    }
    if (head == nil) return NO;
    if (!channel.fastTransfers || head.blocks == nil) {
        [head.blocks laneDown:session.sessionID];
        [channel closeWithReason:SZFriendsCloseReasonNormal];
        return YES;
    }
    __weak SZFPeerSession *weakSession = session;
    __weak SZFriendsBlockExchange *weakBlocks = head.blocks;
    uint64_t lane = session.sessionID;
    channel.onWritten = ^{
        [weakBlocks written:lane];
    };
    [head.blocks laneUp:lane
                   send:^BOOL(SZFriendsFrame *frame) {
                       return [weakSession.channel sendFrame:frame];
                   }
                 queued:^NSUInteger {
                     return weakSession.channel.queuedBulkFrames;
                 }];
    // The lane's peer hears it every second while the group lasts.
    [channel setLivenessKeepalive:YES watch:NO];
    NSMutableDictionary *laneEvent = [event mutableCopy];
    laneEvent[@"lane_of"] = @(head.sessionID);
    [self emit:laneEvent];
    return YES;
}

- (void)establishedSession:(SZFPeerSession *)session {
    SZFriendsSecureChannel *channel = session.channel;
    NSDictionary *established = @{
        @"event" : @"established", @"session" : @(session.sessionID), @"initiator" : @(channel.isInitiator),
        @"pattern" : SZFPatternNames[channel.pattern],
        @"remote_identity" : channel.remoteIdentityKey ? SZFHex(channel.remoteIdentityKey) : [NSNull null],
        @"token" : channel.presentedRequestToken ? SZFHex(channel.presentedRequestToken) : [NSNull null],
        @"route" : @(channel.initiatorRoute), @"minor" : @(channel.negotiatedMinor),
        @"fast" : @(channel.fastTransfers),
    };
    if ([self laneEstablished:session event:established]) return;
    [self emit:established];
    [self devicesEstablished:session];
    SZFriendsPersonRecord *person =
        channel.remoteIdentityKey ? [self.store personWithIdentityKey:channel.remoteIdentityKey] : nil;
    if (person == nil) return;
    session.conversationID = person.conversationID;
    [self blocksOf:session];
    NSArray *unfinished = [self.transfers unfinishedIncomingTransfersForConversation:person.conversationID];
    if (unfinished.count) [self.transfers flushProgressWithError:NULL];
    for (SZFriendsTransferRecord *__strong record in unfinished) {
        record = [self.transfers transferWithID:record.transferID] ?: record;
        if ([session.blocks resumeIncoming:record]) continue; // from exactly what is missing (ADR 0018 § 4)
        if (session.blocks == nil && [self.transfers hasOfferedTree:record.transferID]) {
            [self.transfers dropBlocks:record.transferID];
        }
        SZFriendsChunkReceiver *receiver =
            [[SZFriendsChunkReceiver alloc] initWithOfferID:SZFBytes(record.transferID) size:record.size
                                             verifiedOffset:record.verifiedBytes route:channel.initiatorRoute];
        if (receiver == nil) continue;
        session.receivers[record.transferID] = receiver;
        [channel sendFrame:[receiver resumeProgressFrame]];
    }
    SZFUpdateLiveness(session);
}

- (void)session:(SZFPeerSession *)session receivedFrame:(SZFriendsFrame *)frame {
    if (session.laneHead != nil) {
        // Frames on a lane are its head's; block frames keep their lane, so a PART's HAVE goes back where it came from.
        SZFPeerSession *head = session.laneHead;
        [head.blocks heard:session.sessionID];
        if (frame.type == SZFriendsFrameTypeHashes || frame.type == SZFriendsFrameTypeWant ||
            frame.type == SZFriendsFrameTypePart || frame.type == SZFriendsFrameTypeHave) {
            if (head.blocks == nil || ![head.blocks handleFrame:frame lane:session.sessionID]) {
                [self closeForProtocol:session];
            }
            return;
        }
        session = head;
    }
    [session.blocks heard:session.blocks.controlLane];
    if ([self devicesSession:session frame:frame]) return;
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSString *offer = wire ? SZFHex(wire) : nil;
    BOOL handled = NO;
    switch (frame.type) {
    case SZFriendsFrameTypeOffer: handled = [self session:session offer:frame id:offer]; break;
    case SZFriendsFrameTypeOfferReply: handled = [self session:session offerReply:frame id:offer]; break;
    case SZFriendsFrameTypeProgress: handled = [self session:session progress:frame id:offer]; break;
    case SZFriendsFrameTypeChunk: handled = [self session:session chunk:frame id:offer]; break;
    case SZFriendsFrameTypeDone: handled = [self session:session done:frame id:offer]; break;
    case SZFriendsFrameTypeAck: handled = [self session:session acknowledged:offer]; break;
    case SZFriendsFrameTypeRequestByID: handled = [self session:session requestByID:frame]; break;
    case SZFriendsFrameTypeHashes:
    case SZFriendsFrameTypeWant:
    case SZFriendsFrameTypePart:
    case SZFriendsFrameTypeHave:
        if (session.blocks == nil || ![session.blocks handleFrame:frame]) [self closeForProtocol:session];
        handled = YES;
        break;
    default: break;
    }
    if (handled) {
        SZFUpdateLiveness(session);
        return;
    }
    [self emit:@{@"event" : @"frame", @"session" : @(session.sessionID), @"type" : @(frame.type),
                 @"frame" : SZFHex(SZFriendsEncodeFrame(frame, NULL))}];
}

- (void)closeForProtocol:(SZFPeerSession *)session {
    [session.channel closeWithReason:SZFriendsCloseReasonProtocolError];
}

- (BOOL)session:(SZFPeerSession *)session offer:(SZFriendsFrame *)frame id:(NSString *)offer {
    uint64_t size = 0;
    NSString *name = [frame stringForTag:SZFriendsFieldName];
    NSData *digest = [frame dataForTag:SZFriendsFieldDigest];
    if (session.conversationID == nil || offer == nil || name == nil || digest == nil ||
        ![frame getUInt64:&size forTag:SZFriendsFieldSize]) {
        [self closeForProtocol:session];
        return YES;
    }
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    NSError *error = nil;
    NSString *type = [frame stringForTag:SZFriendsFieldFileType];
    SZFriendsTransferRecord *record = [self.transfers recordIncomingOfferWithID:offer
                                                                 conversationID:session.conversationID
                                                                       fileName:name
                                                                    uniformType:type
                                                                           size:size
                                                                  contentDigest:digest
                                                                         sentAt:[NSDate date]
                                                                          error:&error];
    if (record != nil) [session.blocks noteOffer:frame transferID:offer];
    BOOL accepted = record != nil && [self.transfers acceptTransfer:offer automatically:NO error:&error];
    // From what is here already: nothing, or all of it when the same file was held here (ADR 0018 § 9.5).
    uint64_t held = accepted ? [self.transfers transferWithID:offer].verifiedBytes : 0;
    if (accepted && held == size) [self.transfers dropBlocks:offer];
    BOOL byBlocks = accepted && session.blocks != nil && [self.transfers hasOfferedTree:offer];
    SZFriendsChunkReceiver *receiver =
        accepted && !byBlocks ? [[SZFriendsChunkReceiver alloc] initWithOfferID:wire size:size verifiedOffset:held
                                                                           route:session.channel.initiatorRoute]
                              : nil;
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeAck, wire, nil)];
    NSMutableDictionary *reply = [@{@(SZFriendsFieldAccept) : [SZFriendsFrame fieldWithUInt64:accepted
                                                                                         tag:SZFriendsFieldAccept],
                                    @(SZFriendsFieldOffset) : [SZFriendsFrame fieldWithUInt64:held
                                                                                         tag:SZFriendsFieldOffset]}
        mutableCopy];
    if (byBlocks) [SZFriendsBlockExchange addBlocksToReply:reply forTransfer:offer transfers:self.transfers];
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeOfferReply, wire, reply)];
    if (!accepted) {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
        return YES;
    }
    if (byBlocks) {
        [session.blocks resumeIncoming:[self.transfers transferWithID:offer]];
        [self emit:@{@"event" : @"offer", @"session" : @(session.sessionID), @"transfer" : offer, @"size" : @(size)}];
        return YES;
    }
    session.receivers[offer] = receiver;
    [self emit:@{@"event" : @"offer", @"session" : @(session.sessionID), @"transfer" : offer, @"size" : @(size)}];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session
    startSending:(NSString *)offer
        accepted:(BOOL)accepted
          offset:(uint64_t)offset {
    NSError *error = nil;
    if (session.conversationID == nil ||
        ![self.transfers peerAnsweredTransfer:offer accepted:accepted offset:offset
                             fromConversation:session.conversationID error:&error]) {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
        return NO;
    }
    if (!accepted) {
        [self emit:@{@"event" : @"declined", @"transfer" : offer}];
        return YES;
    }
    SZFriendsTransferRecord *record = [self.transfers transferWithID:offer];
    NSFileHandle *source = record.stagedPath ? SZFriendsOpenSnapshotForSending(record.stagedPath) : nil;
    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:SZFBytes(offer) size:record.size
                                                                    resumeOffset:offset
                                                                           route:session.channel.initiatorRoute];
    if (source == nil || sender == nil) return NO;
    session.senders[offer] = sender;
    session.sources[offer] = source;
    [self emit:@{@"event" : @"sending", @"session" : @(session.sessionID), @"transfer" : offer, @"offset" : @(offset)}];
    [self pumpSession:session];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session offerReply:(SZFriendsFrame *)frame id:(NSString *)offer {
    uint64_t accept = 0, offset = 0, blocks = 0;
    [frame getUInt64:&accept forTag:SZFriendsFieldAccept];
    [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
    if (accept == 1 && offer != nil && [frame getUInt64:&blocks forTag:SZFriendsFieldBlocks] && blocks == 1 &&
        [session.blocks offerTakenByBlocks:offer]) {
        [self emit:@{@"event" : @"sending", @"session" : @(session.sessionID), @"transfer" : offer, @"offset" : @0,
                     @"blocks" : @YES}];
        return YES;
    }
    if (offer == nil || ![self session:session startSending:offer accepted:accept == 1 offset:offset]) {
        [self closeForProtocol:session];
    }
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session progress:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkSender *sender = offer ? session.senders[offer] : nil;
    if (sender != nil) {
        if (![sender handleProgressFrame:frame error:NULL]) [self closeForProtocol:session];
        else [self pumpSession:session];
        return YES;
    }
    uint64_t offset = 0;
    [frame getUInt64:&offset forTag:SZFriendsFieldOffset];
    if (offer == nil || ![self session:session startSending:offer accepted:YES offset:offset]) {
        [self closeForProtocol:session];
    }
    return YES;
}

- (void)reportProgressOnSession:(SZFPeerSession *)session transfer:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = session.receivers[offer];
    uint64_t durable = [self.transfers transferWithID:offer].verifiedBytes;
    if (receiver == nil || durable <= receiver.reportedOffset) return;
    SZFriendsFrame *progress = [receiver progressFrameForDurableOffset:durable];
    if (progress) [session.channel sendFrame:progress];
}

- (void)armFlushOnSession:(SZFPeerSession *)session {
    if (session.flushArmed) return;
    session.flushArmed = YES;
    __weak SZFPeerSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFProgressFlushDelay * NSEC_PER_SEC)), self.queue, ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession == nil) return;
        strongSession.flushArmed = NO;
        [self.transfers flushProgressWithError:NULL];
        for (NSString *offer in strongSession.receivers.allKeys) {
            [self reportProgressOnSession:strongSession transfer:offer];
        }
    });
}

- (BOOL)session:(SZFPeerSession *)session chunk:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = offer ? session.receivers[offer] : nil;
    uint64_t offset = receiver.receivedOffset;
    NSData *data = [receiver acceptChunkFrame:frame error:NULL];
    if (data == nil || ![self.transfers appendChunk:data atOffset:offset toTransfer:offer
                                   fromConversation:session.conversationID error:NULL]) {
        [self closeForProtocol:session]; // unsolicited, out of place, or not stored
        return YES;
    }
    [self reportProgressOnSession:session transfer:offer];
    [self armFlushOnSession:session];
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session done:(SZFriendsFrame *)frame id:(NSString *)offer {
    SZFriendsChunkReceiver *receiver = offer ? session.receivers[offer] : nil;
    NSData *digest = [receiver acceptDoneFrame:frame error:NULL];
    if (digest == nil) {
        [self closeForProtocol:session];
        return YES;
    }
    [session.receivers removeObjectForKey:offer];
    NSError *error = nil;
    if ([self.transfers finishTransfer:offer finalDigest:digest fromConversation:session.conversationID
                                 error:&error]) {
        [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeAck, [frame dataForTag:SZFriendsFieldID], nil)];
        NSString *path = [self.transfers transferWithID:offer].receivedPath ?: @"";
        [self emit:@{@"event" : @"received_file", @"transfer" : offer, @"path" : path}];
    } else {
        [self emit:@{@"event" : @"transfer_failed", @"transfer" : offer, @"why" : error.localizedDescription ?: @""}];
    }
    return YES;
}

// The offer's ACK moves it to Offered; the ACK after DONE says their device verified the file.
- (BOOL)session:(SZFPeerSession *)session acknowledged:(NSString *)offer {
    SZFriendsTransferRecord *record = offer ? [self.transfers transferWithID:offer] : nil;
    if (record == nil || !record.outgoing || session.conversationID == nil) return NO;
    if (record.state == SZFriendsTransferStateQueued) {
        [self.transfers markOfferDelivered:offer fromConversation:session.conversationID error:NULL];
    } else if (record.state == SZFriendsTransferStateSending &&
               [self.transfers peerVerifiedTransfer:offer fromConversation:session.conversationID error:NULL]) {
        [session.senders removeObjectForKey:offer];
        [session.sources[offer] closeFile];
        [session.sources removeObjectForKey:offer];
        [session.blocks endTransfer:offer];
        [self emit:@{@"event" : @"delivered", @"transfer" : offer}];
    }
    return YES;
}

- (BOOL)session:(SZFPeerSession *)session requestByID:(SZFriendsFrame *)frame {
    [session.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}]];
    NSData *identity = SZFriendsVerifyRequestByIDFrame(frame, session.channel.handshakeHash);
    if (identity == nil) return YES;
    [self emit:@{
        @"event" : @"request_by_id", @"session" : @(session.sessionID), @"identity_key" : SZFHex(identity),
        @"static_key" : SZFHex([frame dataForTag:SZFriendsFieldStaticKey]),
        @"token" : SZFHex([frame dataForTag:SZFriendsFieldToken]),
        @"callback_secret" : SZFHex([frame dataForTag:SZFriendsFieldCallbackSecret]),
        @"friends_id" : [frame stringForTag:SZFriendsFieldFriendsID] ?: [NSNull null],
    }];
    return YES;
}

// Chunks while the window has room, then DONE; the channel lets messages overtake the queued chunks.
- (void)pumpSession:(SZFPeerSession *)session {
    for (NSString *offer in session.senders.allKeys) {
        SZFriendsChunkSender *sender = session.senders[offer];
        NSFileHandle *source = session.sources[offer];
        uint64_t offset = 0;
        NSUInteger length = 0;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            NSData *data = SZFriendsReadSnapshotAt(source, offset, length);
            SZFriendsFrame *chunk = [sender chunkFrameWithData:data];
            if (chunk == nil || ![session.channel sendFrame:chunk]) return;
        }
        if (sender.allSent && ![session.doneSent containsObject:offer]) {
            SZFriendsTransferRecord *record = [self.transfers transferWithID:offer];
            NSDictionary *digest = @{@(SZFriendsFieldDigest) : record.contentDigest};
            if ([session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeDone, SZFBytes(offer), digest)]) {
                [session.doneSent addObject:offer];
            }
        }
    }
    [session.blocks pump];
    SZFUpdateLiveness(session);
}

// The session's block exchange, made once it is a friend's session that negotiated fast transfers.
- (nullable SZFriendsBlockExchange *)blocksOf:(SZFPeerSession *)session {
    if (session.blocks != nil) return session.blocks;
    if (session.conversationID == nil || !session.channel.fastTransfers) return nil;
    __weak SZFPeerSession *weakSession = session;
    SZFriendsBlockExchange *blocks = [[SZFriendsBlockExchange alloc]
        initWithTransfers:self.transfers
           conversationID:session.conversationID
                    route:session.channel.initiatorRoute
                     send:^BOOL(SZFriendsFrame *frame) {
                         return [weakSession.channel sendFrame:frame];
                     }
                   queued:^NSUInteger {
                       return weakSession.channel.queuedBulkFrames;
                   }];
    __weak SZFriendsBlockExchange *weakBlocks = blocks;
    session.channel.onWritten = ^{
        [weakBlocks written:SZFriendsHeadLane];
    };
    [self wireBlocks:blocks toSession:session];
    if (session.channel.handshakeHash.length == 64) {
        [blocks formGroupWithHandshakeHash:session.channel.handshakeHash initiator:session.channel.isInitiator];
    }
    session.blocks = blocks;
    return blocks;
}

// The scheduler's timers (a lane gone silent, a lane given up), every 0.25 s while the session holds the exchange, as
// the helper's block tick.
- (void)tickBlocksOf:(SZFPeerSession *)session {
    __weak SZFPeerSession *weakSession = session;
    __weak SZFPeer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), self.queue, ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession.blocks == nil || strongSession.channel == nil) return;
        [strongSession.blocks tick];
        [weakSelf tickBlocksOf:strongSession];
    });
}

// The exchange's events, for the session that holds it (its first session, or the lane that took over).
- (void)wireBlocks:(SZFriendsBlockExchange *)blocks toSession:(SZFPeerSession *)session {
    __weak SZFPeerSession *weakSession = session;
    __weak SZFPeer *weakSelf = self;
    [self tickBlocksOf:session];
    blocks.onReceived = ^(NSString *transferID) {
        NSString *path = [weakSelf.transfers transferWithID:transferID].receivedPath ?: @"";
        [weakSelf emit:@{@"event" : @"received_file", @"transfer" : transferID, @"path" : path}];
    };
    // The bench reads the resume point here, as it reads a CHUNK resume's offset.
    blocks.onWanted = ^(NSString *transferID, uint64_t offset, BOOL resumed) {
        (void)resumed;
        [weakSelf emit:@{@"event" : @"sending", @"session" : @(weakSession.sessionID), @"transfer" : transferID,
                         @"offset" : @(offset), @"blocks" : @YES}];
    };
    blocks.onFlushNeeded = ^{
        SZFPeerSession *strongSession = weakSession;
        if (strongSession == nil || strongSession.blockFlushArmed) return;
        strongSession.blockFlushArmed = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), weakSelf.queue, ^{
            strongSession.blockFlushArmed = NO;
            [strongSession.blocks flushDue];
        });
    };
}

- (NSDictionary *)sendFileWithCommand:(NSDictionary *)command {
    SZFPeerSession *session = self.sessions[@([command[@"session"] unsignedLongLongValue])];
    if (session.conversationID == nil) return @{@"error" : @"not a friend's session"};
    NSError *error = nil;
    SZFriendsTransferRecord *record = [self.transfers stageOutgoingFileAtPath:command[@"path"] ?: @""
                                                                     revision:nil
                                                               conversationID:session.conversationID
                                                                        error:&error];
    if (record == nil) return @{@"error" : error.localizedDescription ?: @"stage failed"};
    NSMutableDictionary *fields = [@{
        @(SZFriendsFieldName) : [record.fileName dataUsingEncoding:NSUTF8StringEncoding],
        @(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:record.size tag:SZFriendsFieldSize],
        @(SZFriendsFieldDigest) : record.contentDigest,
    } mutableCopy];
    if (record.uniformType) {
        fields[@(SZFriendsFieldFileType)] = [record.uniformType dataUsingEncoding:NSUTF8StringEncoding];
    }
    [SZFriendsBlockExchange addTreeOfTransfer:record toFields:fields transfers:self.transfers];
    [session.channel sendFrame:SZFIDFrame(SZFriendsFrameTypeOffer, SZFBytes(record.transferID), fields)];
    return @{@"transfer" : record.transferID, @"size" : @(record.size), @"digest" : SZFHex(record.contentDigest)};
}

- (NSDictionary *)requestByIDWithCommand:(NSDictionary *)command {
    SZFPeerSession *session = self.sessions[@([command[@"session"] unsignedLongLongValue])];
    NSData *token = SZFBytes(command[@"token"]) ?: [NSData data];
    NSData *callback = SZFBytes(command[@"callback"]) ?: [NSData data];
    SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(self.identity, command[@"friends_id"] ?: @"", token, callback,
                                                          session.channel.handshakeHash ?: [NSData data]);
    return @{@"sent" : (frame != nil && [session.channel sendFrame:frame]) ? @YES : @NO};
}

@end
