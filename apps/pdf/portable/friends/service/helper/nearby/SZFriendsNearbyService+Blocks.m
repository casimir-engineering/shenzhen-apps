// Files by blocks on a fast session and its lanes (ADR 0018, PROTOCOL.md § Fast transfers): the nearby service's side
// of SZFriendsBlockExchange, one per live friend's first session that negotiated fast transfers ("the head"). The
// exchange moves the frames, schedules blocks across the head and its lanes and asks for lanes; the store keeps the
// blocks. This file ties them to links: lanes dialed and admitted, what is sent where, ACK expectations, durability
// batches and the scheduler's timers on the helper queue, and what a received file sets off.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

// A durability batch comes due at most a second after a block was written (SZFriendsBlockDownloads.m).
static const NSTimeInterval SZFriendsBlockFlushDelay = 0.5;
// The scheduler's timers (silent lanes) run at least this often while the group sends.
static const NSTimeInterval SZFriendsBlockTickInterval = 0.25;

static uint64_t SZFriendsNextLaneSerial = 0;

@implementation SZFriendsNearbyService (Blocks)

- (SZFriendsBlockExchange *)blocksOnLink:(SZFriendsPeerLink *)link {
    if (link.lane) return [self blocksOnLink:link.laneHead];
    if (link.blocks != nil) return link.blocks;
    if (!link.live || link.closed || link.conversationID == nil || !link.channel.fastTransfers) return nil;
    __weak SZFriendsPeerLink *weakLink = link;
    SZFriendsBlockExchange *blocks = [[SZFriendsBlockExchange alloc]
        initWithTransfers:self.services.transfers
           conversationID:link.conversationID
                    route:link.raceRoute
                     send:^BOOL(SZFriendsFrame *frame) {
                         return [weakLink.channel sendFrame:frame];
                     }
                   queued:^NSUInteger {
                       return weakLink.channel.queuedBulkFrames;
                   }];
    if (link.channel.handshakeHash.length == 64) {
        [blocks formGroupWithHandshakeHash:link.channel.handshakeHash initiator:link.channel.isInitiator];
    }
    __weak SZFriendsBlockExchange *weakBlocks = blocks;
    link.channel.onWritten = ^{
        [weakBlocks written:SZFriendsHeadLane];
    };
    blocks.queue = self.queue;
    [self wireBlocks:blocks toLink:link];
    link.blocks = blocks;
    return blocks;
}

// The exchange's events, for the link that holds it: the first session, or the lane that took over from it.
- (void)wireBlocks:(SZFriendsBlockExchange *)blocks toLink:(SZFriendsPeerLink *)link {
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsPeerLink *weakLink = link;
    blocks.onChanged = ^{
        [weakSelf changed];
    };
    blocks.onSending = ^(NSString *transferID) {
        SZFriendsPeerLink *strongLink = weakLink;
        [strongLink.endedTransfers removeObject:transferID];
        [strongLink expectAckForID:transferID token:[@"done:" stringByAppendingString:transferID]];
        [weakSelf scheduleBlockTickOnLink:strongLink];
    };
    blocks.onReceived = ^(NSString *transferID) {
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil || strongLink.closed) {
            // The session that received it ended during the check: acknowledged on the friend's live one.
            NSString *conversationID = [strongSelf.services.transfers transferWithID:transferID].conversationID;
            SZFriendsPeerLink *live = conversationID ? [strongSelf liveLinkForConversation:conversationID] : nil;
            NSData *wire = SZFriendsLinkBytesFromHex(transferID);
            if (live != nil && wire != nil) {
                [live.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAck
                                                               fields:@{@(SZFriendsFieldID) : wire}]];
            }
        }
        // The file is what it claimed to be: our own preview of it now replaces the sender's (+Thumbnails).
        [strongSelf makeLocalThumbnailForReceivedTransfer:transferID];
        [strongSelf.services.notifier noteTransferReceived:transferID];
    };
    blocks.onWanted = ^(NSString *transferID, uint64_t offset, BOOL resumed) {
        if (resumed) {
            SZFriendsHelperLog(@"transfer %@ resumes at byte %llu", [transferID substringToIndex:8],
                               (unsigned long long)offset);
        }
    };
    blocks.pace = ^BOOL(NSUInteger bytes) {
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsPeerLink *strongLink = weakLink;
        double rate = SZFriendsHelperTestHooks.chunkBytesPerSecond;
        if (rate <= 0 || strongSelf == nil || strongLink == nil) return NO;
        if ([strongSelf paceLink:strongLink bytes:bytes rate:rate]) return YES;
        strongLink.paceBytes += bytes;
        return NO;
    };
    blocks.onFlushNeeded = ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongSelf && strongLink) [strongSelf scheduleBlockFlushOnLink:strongLink];
    };
    blocks.onOpenLane = ^(SZFriendsRouteMethod route) {
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink) [weakSelf openLaneOfLink:strongLink route:route];
    };
    blocks.onCloseLane = ^(SZFriendsLaneID lane) {
        for (SZFriendsPeerLink *member in weakLink.lanes.allObjects) {
            if (member.laneSerial == lane) [member.channel closeWithReason:SZFriendsCloseReasonNormal];
        }
    };
}

- (nullable SZFriendsPeerLink *)handOverGroupOfLink:(SZFriendsPeerLink *)head {
    SZFriendsBlockExchange *blocks = head.blocks;
    if (blocks.group == nil || head.lane || head.lanes.count == 0) return nil;
    if ([blocks laneDown:blocks.controlLane]) return nil; // no live lane left
    SZFriendsPeerLink *heir = nil;
    for (SZFriendsPeerLink *lane in head.lanes.allObjects) {
        if (lane.laneSerial == blocks.controlLane && lane.live && !lane.closed) heir = lane;
    }
    if (heir == nil) return nil;
    [head.lanes removeObject:heir];
    heir.lane = NO;
    heir.laneHead = nil;
    for (SZFriendsPeerLink *lane in head.lanes.allObjects) {
        lane.laneHead = heir;
        [heir.lanes addObject:lane];
    }
    [head.lanes removeAllObjects];
    heir.blocks = blocks;
    head.blocks = nil;
    [self wireBlocks:blocks toLink:heir];
    [self scheduleBlockTickOnLink:heir];
    SZFriendsHelperLog(@"the first session of a group ended: a lane on route %ld carries it on",
                       (long)heir.raceRoute);
    return heir;
}

// The scheduler's timers while the group sends: a lane that stopped moving is noticed and its blocks go elsewhere.
- (void)scheduleBlockTickOnLink:(SZFriendsPeerLink *)link {
    if (link.blockTickScheduled || link.closed || link.blocks.sending.count == 0) return;
    link.blockTickScheduled = YES;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsBlockTickInterval * NSEC_PER_SEC)), self.queue,
                   ^{
                       SZFriendsPeerLink *strongLink = weakLink;
                       if (strongLink == nil) return;
                       strongLink.blockTickScheduled = NO;
                       if (strongLink.closed) return;
                       [strongLink.blocks tick];
                       [self scheduleBlockTickOnLink:strongLink];
                   });
}

- (void)scheduleBlockFlushOnLink:(SZFriendsPeerLink *)link {
    if (link.blockFlushScheduled) return;
    link.blockFlushScheduled = YES;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsBlockFlushDelay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil) return;
        strongLink.blockFlushScheduled = NO;
        if (!strongLink.closed) [strongLink.blocks flushDue];
        [self progressChanged];
    });
}

#pragma mark - Lanes

// The friend's device opened a lane (IK message 1 carried a Lane token): admitted into the group of our live fast
// session with that device whose token it names, or refused with CLOSE LaneRefused.
- (void)admitLane:(SZFriendsPeerLink *)link {
    SZFriendsSecureChannel *channel = link.channel;
    for (SZFriendsPeerLink *head in self.links) {
        if (head == link || head.lane || !head.live || head.closed || head.superseded || head.conversationID == nil ||
            !head.channel.fastTransfers || !channel.fastTransfers ||
            ![head.channel.remoteStaticKey isEqualToData:channel.remoteStaticKey] ||
            ![head.channel.remoteIdentityKey isEqualToData:channel.remoteIdentityKey]) {
            continue;
        }
        SZFriendsBlockExchange *blocks = [self blocksOnLink:head];
        uint64_t serial = ++SZFriendsNextLaneSerial;
        if ([blocks admitLane:serial token:channel.presentedLane route:channel.initiatorRoute] !=
            SZFriendsLaneAdmitted) {
            continue;
        }
        link.laneSerial = serial;
        [self joinLane:link toHead:head];
        return;
    }
    SZFriendsHelperLog(@"lane refused: no live session with that device and a free index matches its token");
    [channel closeWithReason:SZFriendsCloseReasonLaneRefused];
}

// A lane is live (admitted, or ours answered): parts may go on it, and its frames count as the head's.
- (void)joinLane:(SZFriendsPeerLink *)link toHead:(SZFriendsPeerLink *)head {
    link.lane = YES;
    link.laneHead = head;
    link.conversationID = head.conversationID;
    [head.lanes addObject:link];
    // The lane's peer always hears something from it while the group lasts, so it never takes it for silent.
    [link.channel setLivenessKeepalive:YES watch:NO];
    __weak SZFriendsPeerLink *weakLink = link;
    SZFriendsBlockExchange *blocks = head.blocks;
    __weak SZFriendsBlockExchange *weakBlocks = blocks;
    uint64_t serial = link.laneSerial;
    link.channel.onWritten = ^{
        [weakBlocks written:serial];
    };
    [blocks laneUp:serial
              send:^BOOL(SZFriendsFrame *frame) {
                  return [weakLink.channel sendFrame:frame];
              }
            queued:^NSUInteger {
                return weakLink.channel.queuedBulkFrames;
            }];
}

// The scheduler asks for a lane on `route`: the friend's device is dialed there, with the next index's token.
- (void)openLaneOfLink:(SZFriendsPeerLink *)head route:(SZFriendsRouteMethod)route {
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:head.conversationID];
    if (head.closed || person.staticKey == nil || person.identityKey == nil) return;
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (![candidate.conversationID isEqualToString:head.conversationID]) continue;
        for (SZFriendsSighting *sighting in candidate.sightings) {
            if (sighting.route != route || sighting.isPublic) continue;
            uint64_t serial = ++SZFriendsNextLaneSerial;
            NSData *token = nil;
            if ([head.blocks reserveLane:serial route:route token:&token] == 0) return;
            SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:route];
            options.requestToken = nil; // a lane never carries an Add by ID callback
            options.lane = token;
            SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting
                                                                  purpose:SZFriendsLinkPurposeFriend
                                                                  options:options];
            plan.laneHead = head;
            plan.laneSerial = serial;
            if (![self dial:plan]) [head.blocks laneDown:serial];
            return;
        }
    }
}

- (void)link:(SZFriendsPeerLink *)link receivedBlockFrame:(SZFriendsFrame *)frame {
    SZFriendsBlockExchange *blocks = [self blocksOnLink:link];
    SZFriendsLaneID lane = link.lane ? link.laneSerial : blocks.controlLane;
    if (blocks == nil || ![blocks handleFrame:frame lane:lane]) {
        // ADR 0001: nothing moves outside an accepted transfer; a block frame that names none closes the session.
        SZFriendsHelperLog(@"a block frame out of place: closing the session");
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    [self updateLivenessOnLink:link.lane ? link.laneHead : link];
    [self progressChanged];
}

@end
