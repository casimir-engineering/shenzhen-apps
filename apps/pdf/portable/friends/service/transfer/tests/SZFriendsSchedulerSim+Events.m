// The simulator's events (SZFriendsSchedulerSim.m), as the Rust core's transfer/sim_events.rs: what each lane event does
// to the scheduler and to the bytes in flight.

#import "SZFriendsSchedulerSimInternal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFSim (Events)

- (void)handle:(SZFEvent)ev {
    int i = ev.lane;
    SZFSimLane *lane = i >= 0 && (NSUInteger)i < _lanes.count ? _lanes[i] : nil;
    switch (ev.kind) {
    case SZFEvUp:
        if (lane->state == SZFIdle && [_group reserve:lane->lane route:lane->profile.route token:NULL] == 0) return;
        lane->state = SZFUp;
        if ([_out.laneUpAt[i] doubleValue] < 0) _out.laneUpAt[i] = @(_now);
        [_group laneUp:lane->lane];
        [self at:_now + 1 event:SZFMake(SZFEvPing, i)];
        [self feedGroup];
        [self act];
        return;
    case SZFEvCut:
        if (lane->state == SZFUp) {
            [self cut:i];
            [self at:_now + lane->profile.detect event:SZFMake(SZFEvNotice, i)];
        }
        return;
    case SZFEvNotice: [self notice:i]; return;
    case SZFEvTxDone: {
        if (lane->epoch != ev.epoch || !lane->busy) return;
        SZFPart part = lane->current;
        lane->busy = NO;
        BOOL directWorks = NO;
        for (SZFSimLane *other in _lanes) {
            directWorks |= other->profile.route != SZFriendsRouteMethodRelay && other->state == SZFUp &&
                           ![other->profile silentAt:_now];
        }
        if (lane->profile.route == SZFriendsRouteMethodRelay && directWorks) {
            _out.relayBesideDirectBytes += part.to - part.from;
        }
        _out.laneSentBytes[i] = @([_out.laneSentBytes[i] unsignedLongLongValue] + part.to - part.from);
        _out.laneLastWrite[i] = @(_now);
        if ([_out.laneFirstWrite[i] doubleValue] < 0) _out.laneFirstWrite[i] = @(_now);
        double arrive = [lane->profile advance:_now by:lane->profile.rtt / 2];
        SZFEvent event = SZFMake(SZFEvArrive, i);
        event.epoch = ev.epoch;
        event.block = part.block;
        event.from = part.from;
        event.to = part.to;
        [self at:arrive event:event];
        if (lane->profile.buffer > 0) {
            // Written when it went into the buffer.
            lane->bufferedBytes -= part.to - part.from;
            if (++lane->bufferedHead == lane->buffered.length / sizeof(SZFPart)) {
                lane->buffered = [NSMutableData data];
                lane->bufferedHead = 0;
            }
        } else {
            [_scheduler written:lane->lane now:_now];
            if (part.last) [_scheduler sent:lane->lane transfer:SZFKey block:part.block now:_now];
        }
        [self transmit:i];
        [self act];
        return;
    }
    case SZFEvArrive: {
        if (lane->epoch != ev.epoch) return;
        uint8_t *complete = _complete.mutableBytes;
        if (complete[ev.block]) {
            // A late copy: dropped, and answered with a HAVE for that block once per lane, as the HAVE that said so
            // may have gone with a lane that fell silent.
            _out.wastedBytes += ev.to - ev.from;
            if (![_answered containsObject:@(((uint64_t)i << 32) | ev.block)]) {
                [_answered addObject:@(((uint64_t)i << 32) | ev.block)];
                [self sendBack:i block:ev.block want:NO];
            }
            return;
        }
        uint64_t start = 0;
        NSUInteger length = 0;
        SZFriendsGeometrySpan(_geometry, ev.block, &start, &length);
        uint64_t *bits = _covered[ev.block].mutableBytes;
        BOOL fresh = NO;
        uint64_t end = (ev.to - start + SZFGranule - 1) / SZFGranule;
        for (uint64_t g = (ev.from - start) / SZFGranule; g < end; g++) {
            fresh |= (bits[g / 64] & (1ull << (g % 64))) == 0;
            bits[g / 64] |= 1ull << (g % 64);
        }
        if (!fresh) _out.wastedBytes += ev.to - ev.from;
        uint64_t needed = MAX((length + SZFGranule - 1) / SZFGranule, (uint64_t)1), have = 0;
        for (NSUInteger w = 0; w < _covered[ev.block].length / 8; w++) have += (uint64_t)__builtin_popcountll(bits[w]);
        if (have >= needed) {
            complete[ev.block] = 1;
            [self sendBack:i block:ev.block want:NO];
        }
        return;
    }
    case SZFEvBack:
        if (lane->epoch != ev.epoch) {
            [self sendBack:i block:ev.block want:ev.want];
            return;
        }
        [_scheduler heard:lane->lane now:_now];
        if (ev.want) {
            [_scheduler want:SZFKey ranges:SZFriendsRange(ev.block, 1) now:_now];
            [self act];
            return;
        }
        [_scheduler have:SZFKey ranges:SZFriendsRange(ev.block, 1) now:_now];
        if ([_scheduler isDone:SZFKey]) {
            _out.doneAt = _now;
            return;
        }
        [self act];
        return;
    case SZFEvPing: {
        if (lane->state != SZFUp) return;
        SZFEvent heard = SZFMake(SZFEvHeard, i);
        heard.epoch = lane->epoch;
        [self at:[lane->profile advance:_now by:lane->profile.rtt / 2] event:heard];
        [self at:_now + 1 event:SZFMake(SZFEvPing, i)];
        return;
    }
    case SZFEvHeard:
        if (lane->epoch == ev.epoch && lane->state == SZFUp) [_scheduler heard:lane->lane now:_now];
        return;
    case SZFEvTimer:
        if (_timerArmed && _timerAt == _now) {
            _timerArmed = NO;
            [_scheduler tick:_now];
            [self act];
        }
        return;
    }
}

@end

NS_ASSUME_NONNULL_END
