// SZFriendsSecureChannel: liveness while a transfer runs (ADR 0018 § 7; the Rust core's session/liveness.rs).
//
// A route that goes out of range stays open to TCP and L2CAP for minutes, so the session notices instead: its driver
// says when a transfer needs it (-setLivenessKeepalive:watch:), the channel sends PING after a keepalive without
// sending anything, so the peer always hears something, and closes after the silence limit without hearing a byte.

#import "service/session/SZFriendsSecureChannelInternal.h"

#import "service/session/SZFriendsFrameSchema.h"

@implementation SZFriendsSecureChannel (Liveness)

- (void)applyLivenessKeepalive:(BOOL)keepalive watch:(BOOL)watch {
    NSTimeInterval now = [self now];
    if (keepalive && !_keepalive) {
        // A PING is due at once only if nothing went out for a keepalive already.
        _lastSentAt = MAX(_lastSentAt, now - _keepaliveInterval);
    }
    if (watch && !_watchSilence) {
        _lastHeardAt = now;
        _livenessCheckedAt = now;
    }
    _keepalive = keepalive;
    _watchSilence = watch;
    [self armLivenessTimer];
}

- (void)noteSent:(NSTimeInterval)now {
    _lastSentAt = now;
}

- (void)noteHeard:(NSTimeInterval)now {
    _lastHeardAt = now;
}

- (NSTimeInterval)silenceLimit {
    return self.initiatorRoute == SZFriendsRouteMethodBluetooth ? _silenceLimitBluetooth : _silenceLimit;
}

// The earlier of the next PING and the silence limit. While watching it wakes at least every keepalive, so a longer
// gap between runs can only mean this side stalled.
- (NSTimeInterval)livenessDeadline {
    NSTimeInterval deadline = DBL_MAX;
    if (_keepalive) deadline = _lastSentAt + _keepaliveInterval;
    if (_watchSilence) {
        deadline = MIN(deadline, MIN(_lastHeardAt + [self silenceLimit], _livenessCheckedAt + _keepaliveInterval));
    }
    return deadline;
}

// One timer at a time. Sending and hearing only move the deadline later, so a timer that fires early just looks
// again and re-arms.
- (void)armLivenessTimer {
    if (_livenessTimerArmed || !(_keepalive || _watchSilence) || _state != SZFriendsChannelStateEstablished) return;
    _livenessTimerArmed = YES;
    NSTimeInterval delay = MAX([self livenessDeadline] - [self now], 0.001);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        SZFriendsSecureChannel *channel = weakSelf;
        if (channel == nil) return;
        channel->_livenessTimerArmed = NO;
        [channel checkLiveness];
        [channel armLivenessTimer];
    });
}

- (void)checkLiveness {
    if (_state != SZFriendsChannelStateEstablished) return;
    NSTimeInterval now = [self now];
    if (_watchSilence) {
        // This side did not run for a while (its queue was busy, or the Mac slept): whatever the peer sent may still
        // be waiting to be read, so its silence counts from now.
        if (_livenessCheckedAt > 0 && now - _livenessCheckedAt > _keepaliveInterval * 2) {
            _lastHeardAt = MAX(_lastHeardAt, now);
        }
        _livenessCheckedAt = now;
        if (now - _lastHeardAt >= [self silenceLimit]) {
            [self terminateWithError:SZFriendsSessionMakeError(SZFriendsSessionErrorSilent,
                                                               @"nothing heard while a transfer ran")
                         closeReason:-1];
            return;
        }
    }
    // One PING at a time: when the link takes nothing (a silent route), the next waits for another keepalive.
    if (_keepalive && now - _lastSentAt >= _keepaliveInterval && _controlQueue.count == 0) {
        _lastSentAt = now;
        [self enqueueChannelFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypePing fields:@{}]];
        [self pumpWrites];
    }
}

@end
