// The limits of SZFriendsNearbyLimits.h applied to live links: the cap on sessions with people who are not friends,
// and how long such a session may sit idle or last at all. The admission rates are the adapters'
// (SZFriendsAdmissionLimits).

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

@implementation SZFriendsNearbyService (Limits)

- (NSUInteger)strangerLinkCount {
    NSUInteger count = 0;
    for (SZFriendsPeerLink *link in self.links) {
        if (!link.stranger || link.closed) continue;
        // A request accepted meanwhile made this a friend's session, which no longer takes a stranger's place.
        if (link.live && [self linkIsWithFriend:link]) {
            link.stranger = NO;
            continue;
        }
        count++;
    }
    return count;
}

// The cap is full: the stranger session that moved forward least recently closes so the newcomer can come in. WHY
// not refuse the newcomer: then whoever filled the cap first, with sessions that say nothing new, would keep every
// later request out for as long as they liked (review: stranger sessions). Returns NO when there is nobody to close.
- (BOOL)makeRoomForStranger {
    SZFriendsPeerLink *idlest = nil;
    NSDate *idlestSince = nil;
    for (SZFriendsPeerLink *link in self.links) {
        if (!link.stranger || link.closed) continue;
        NSDate *since = link.lastApplicationFrameAt ?: link.liveAt ?: link.createdAt;
        if (idlest == nil || [since compare:idlestSince] == NSOrderedAscending) {
            idlest = link;
            idlestSince = since;
        }
    }
    if (idlest == nil) return NO;
    // No longer counted from now on: its CLOSE goes out after what it has queued.
    idlest.stranger = NO;
    [idlest.channel closeWithReason:SZFriendsCloseReasonNormal];
    return YES;
}

- (BOOL)linkIsWithFriend:(SZFriendsPeerLink *)link {
    if (link.ownDevice) return YES; // another device of ours: no stranger's limits (+Sync)
    if (link.channel.pattern == SZFriendsHandshakeNN || link.conversationID == nil) return NO;
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:link.conversationID];
    return person.relation == SZFriendsRelationFriend;
}

- (NSTimeInterval)idleTimeout {
    NSTimeInterval override = SZFriendsHelperTestHooks.strangerIdleTimeout;
    return override > 0 ? override : SZFriendsStrangerIdleTimeout;
}

- (NSTimeInterval)strangerSessionLife {
    NSTimeInterval override = SZFriendsHelperTestHooks.strangerSessionLife;
    return override > 0 ? override : SZFriendsStrangerSessionLife;
}

- (void)noteApplicationFrameOnLink:(SZFriendsPeerLink *)link {
    link.lastApplicationFrameAt = [NSDate date];
}

// What moves a request forward: the first PROFILE and the first REQUEST, the first answer, and an ACK of something
// this link sent. Anything else (a second PROFILE, a MESSAGE or CANCEL a stranger may not send, an ACK for nothing)
// leaves the idle clock running, so repeating a frame cannot keep a stranger's session open until its 24-hour
// maximum (review: idle limits). Friends' sessions have no idle limit, so for them this decides nothing.
- (void)noteFrame:(SZFriendsFrame *)frame onLink:(SZFriendsPeerLink *)link {
    BOOL advances = NO;
    switch (frame.type) {
    case SZFriendsFrameTypeProfile:
        advances = !link.profileReceived;
        link.profileReceived = YES;
        break;
    case SZFriendsFrameTypeRequest:
        advances = !link.requestReceived;
        link.requestReceived = YES;
        break;
    case SZFriendsFrameTypeAccept:
    case SZFriendsFrameTypeDecline:
        advances = !link.answerReceived;
        link.answerReceived = YES;
        break;
    case SZFriendsFrameTypeAck: {
        NSData *wire = [frame dataForTag:SZFriendsFieldID];
        advances = wire != nil && [link expectsAckForID:SZFriendsLinkHex(wire)];
        break;
    }
    default:
        break;
    }
    if (advances) [self noteApplicationFrameOnLink:link];
}

// Friends' sessions have no idle limit (the 24-hour redial bounds them); anyone else's ends after a quiet minute,
// and after three minutes in any case, so a nearby device cannot hold channels, buffers and descriptors open (review:
// NN and stranger sessions kept alive indefinitely). Checked again when the person becomes a friend meanwhile.
- (void)armIdleCheckForLink:(SZFriendsPeerLink *)link {
    if (link.lastApplicationFrameAt == nil) link.lastApplicationFrameAt = link.liveAt ?: [NSDate date];
    NSTimeInterval idleWait = [self idleTimeout] + link.lastApplicationFrameAt.timeIntervalSinceNow;
    NSTimeInterval lifeWait = [self strangerSessionLife] + (link.liveAt ?: link.createdAt).timeIntervalSinceNow;
    [self scheduleIdleCheckForLink:link after:MIN(idleWait, lifeWait)];
}

- (void)scheduleIdleCheckForLink:(SZFriendsPeerLink *)link after:(NSTimeInterval)delay {
    if (link.closed || link.idleCheckScheduled) return;
    NSTimeInterval wait = MAX(0.05, delay);
    link.idleCheckScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil) return;
        strongLink.idleCheckScheduled = NO;
        [weakSelf idleCheckLink:strongLink];
    });
}

- (void)idleCheckLink:(SZFriendsPeerLink *)link {
    if (link.closed || self.shutDown) return;
    if ([self linkIsWithFriend:link]) {
        // No limit for a friend. Looked at again in a while, not at once: a friend's quiet session would otherwise
        // be checked continuously, and a removed person's session stays only to deliver the answer they wait for.
        [self scheduleIdleCheckForLink:link after:[self idleTimeout]];
        return;
    }
    BOOL quiet = -link.lastApplicationFrameAt.timeIntervalSinceNow >= [self idleTimeout] - 0.01;
    BOOL old = -(link.liveAt ?: link.createdAt).timeIntervalSinceNow >= [self strangerSessionLife] - 0.01;
    if (quiet || old) {
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        return;
    }
    [self armIdleCheckForLink:link];
}

- (void)closeLink:(SZFriendsPeerLink *)link after:(NSTimeInterval)delay {
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink != nil && !strongLink.closed) [strongLink.channel close];
    });
}

@end
