// Reset Friends (ADR 0005 step 6): a signed release over the open connection, or over one opened just for it,
// answered within the release timeout or reported as unconfirmed. The client stops for good either way.

#import "service/host/SZFriendsCheckInClientPrivate.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

@implementation SZFriendsCheckInClient (Release)

- (void)startReleaseWithCompletion:(void (^)(BOOL released))completion {
    void (^callback)(BOOL) = [completion copy];
    dispatch_async(_queue, ^{
        if (self->_releaseCompletion) {
            callback(NO); // one release at a time; the first one decides
            return;
        }
        self->_releaseCompletion = callback;
        self->_running = NO;
        // Whatever the host answers, this identity is being reset; nothing a host said about it is shown again.
        [self forgetAttestation];
        SZFriendsHostCancelTimer(&self->_retryTimer);
        SZFriendsHostCancelTimer(&self->_reserveTimer);
        if (self->_pathMonitor) {
            nw_path_monitor_cancel(self->_pathMonitor);
            self->_pathMonitor = nil;
        }
        self->_releaseTimer = [self timerAfter:self.releaseTimeout
                                       handler:^(SZFriendsCheckInClient *client) {
                                           [client finishRelease:NO];
                                       }];
        if (self->_phase == SZFriendsCheckInPhaseCheckedIn && self->_challenge) {
            [self sendRelease];
        } else {
            [self beginRound];
        }
    });
}

- (void)sendRelease {
    SZFriendsHostEntry *entry = _candidates[_candidateIndex].entry;
    NSString *friendsID = _originalID ?: (_idProvider ? _idProvider(0) : @"");
    NSData *signed_ = SZFriendsHostReleaseMessage(entry.hostID, _challenge, _identity.publicKey, friendsID);
    NSData *signature = [_identity signatureForMessage:signed_ domain:SZFriendsHostReleaseDomain];
    _phase = SZFriendsCheckInPhaseReleasing;
    [self send:@"release"
        fields:@{
            @"identity_key" : SZFriendsHostBase64URLEncode(_identity.publicKey),
            @"friends_id" : friendsID,
            @"sig" : SZFriendsHostBase64URLEncode(signature),
        }];
}

- (void)finishRelease:(BOOL)released {
    void (^completion)(BOOL) = _releaseCompletion;
    if (!completion) return;
    _releaseCompletion = nil;
    SZFriendsHostCancelTimer(&_releaseTimer);
    [self closeSocket];
    [self setState:SZFriendsHostStateStopped];
    completion(released);
}

@end
