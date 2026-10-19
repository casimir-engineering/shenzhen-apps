// Joining a profile, nearby (SZFriendsNearbyJoin.h): the new computer's NN sessions to every device it cannot
// recognise, as Add by ID's, carrying JOIN frames; every device's side of them; and a session's end. What the
// messages mean is +Join's, through the pipe each link gets.

#import "service/helper/nearby/SZFriendsNearbyJoin.h"

#import <objc/runtime.h>

// A nearby NN session as a pipe: JOIN frames, RECEIVED like every device, and the close Add by ID uses.
@interface SZFriendsJoinLinkPipe : NSObject <SZFriendsJoinPipe>
@property(nonatomic, weak) SZFriendsNearbyService *service;
@property(nonatomic, weak) SZFriendsPeerLink *link;
@end

@implementation SZFriendsJoinLinkPipe

- (NSData *)handshakeHash {
    return self.link.channel.handshakeHash;
}

- (BOOL)sendJoinMessages:(NSArray<NSData *> *)messages {
    BOOL sent = YES;
    for (NSData *message in messages) {
        SZFriendsFrame *frame = [SZFriendsFrame frameWithType:SZFriendsFrameTypeJoin
                                                       fields:@{@(SZFriendsFieldJoin) : message}];
        sent = [self.link.channel sendFrame:frame] && sent;
    }
    return sent;
}

- (void)sendReceived {
    [self.link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}]];
}

- (void)finish {
    SZFriendsPeerLink *link = self.link;
    if (link != nil) [self.service closeLink:link after:SZFriendsByIDReplyLinger];
}

@end

@implementation SZFriendsNearbyService (JoinNearby)

// Nearby pipes live as long as their link: one per link, so every frame of a run meets the same approval or attempt.
- (NSMapTable<SZFriendsPeerLink *, SZFriendsJoinLinkPipe *> *)joinLinkPipes {
    static const void *key = &key;
    NSMapTable *pipes = objc_getAssociatedObject(self, key);
    if (pipes == nil) {
        pipes = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality |
                                                   NSPointerFunctionsStrongMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
        objc_setAssociatedObject(self, key, pipes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return pipes;
}

- (SZFriendsJoinLinkPipe *)pipeForLink:(SZFriendsPeerLink *)link {
    SZFriendsJoinLinkPipe *pipe = [self.joinLinkPipes objectForKey:link];
    if (pipe == nil) {
        pipe = [SZFriendsJoinLinkPipe new];
        pipe.service = self;
        pipe.link = link;
        [self.joinLinkPipes setObject:pipe forKey:link];
    }
    return pipe;
}

#pragma mark - Nearby

// Like Add by ID: every device we cannot recognise, hidden or public, gets an NN session; the request once per
// presence window, each code once.
- (void)offerJoinNearby {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoiningState phase = state.phase;
    if (state.joiner == nil || self.coordinator == nil) return;
    BOOL code = phase == SZFriendsJoiningChecking;
    if (!code && phase != SZFriendsJoiningWaiting && phase != SZFriendsJoiningWrongCode &&
        phase != SZFriendsJoiningNotReached) {
        return;
    }
    NSMutableArray<SZFriendsCandidate *> *devices = [self.coordinator.merger.unmatchedDevices mutableCopy];
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (candidate.conversationID == nil && candidate.isPublic) [devices addObject:candidate];
    }
    NSString *request = SZFriendsLinkHex(state.joiner.requestID);
    for (SZFriendsCandidate *device in devices) {
        SZFriendsSighting *sighting = device.sightings.firstObject;
        if (sighting == nil) continue;
        NSString *key = code ? [NSString stringWithFormat:@"joincode|%lu|%@", (unsigned long)state.generation,
                                                          sighting.endpointID]
                             : [NSString stringWithFormat:@"join|%@|%@|%lld", request, sighting.endpointID,
                                                          (long long)[self currentWindow]];
        if (self.attempts[key] != nil) continue;
        self.attempts[key] = [NSDate dateWithTimeIntervalSinceNow:code ? 60 : SZFriendsPresenceWindow];
        SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
        options.pattern = SZFriendsHandshakeNN;
        options.route = sighting.route;
        SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting purpose:SZFriendsLinkPurposeJoin
                                                              options:options];
        plan.attemptKey = key;
        [self dial:plan];
    }
}

- (void)joinLinkWentLive:(SZFriendsPeerLink *)link {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoinLinkPipe *pipe = [self pipeForLink:link];
    // Every NN session ends soon, whatever was asked on it.
    [self closeLink:link after:SZFriendsByIDSessionLife];
    NSString *codeKey = [NSString stringWithFormat:@"joincode|%lu|", (unsigned long)state.generation];
    if ([link.attemptKey hasPrefix:codeKey]) {
        [self beginCodeLegOnPipe:pipe];
        return;
    }
    NSData *request = [link.attemptKey hasPrefix:@"join|"] ? [state.joiner requestMessageAtDate:[NSDate date]] : nil;
    if (request == nil || ![pipe sendJoinMessages:@[ request ]]) [pipe finish];
}

- (void)link:(SZFriendsPeerLink *)link receivedJoinFrame:(SZFriendsFrame *)frame {
    NSData *message = [frame dataForTag:SZFriendsFieldJoin];
    SZFriendsJoinLinkPipe *pipe = [self pipeForLink:link];
    if (message == nil) {
        [pipe finish];
        return;
    }
    [self pipe:pipe receivedJoinMessage:message initiator:link.channel.isInitiator];
}

- (void)joinLinkEnded:(SZFriendsPeerLink *)link {
    SZFriendsJoinLinkPipe *pipe = [self.joinLinkPipes objectForKey:link];
    if (pipe == nil) return;
    [self.joinLinkPipes removeObjectForKey:link];
    [self pipeEnded:pipe];
}

@end
