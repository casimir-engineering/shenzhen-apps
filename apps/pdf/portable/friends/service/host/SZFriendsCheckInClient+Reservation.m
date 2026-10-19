// The answer to a reservation (ADR 0005 § Check-in), in a welcome or after a collision: the ID it reserved, a rename
// after collisions, a new draw while the host says taken (never on a device that joined a profile), and asking again
// later while the main host is down behind a replica. Everything runs on the client's queue.

#import "service/host/SZFriendsCheckInClientPrivate.h"
#import "service/host/SZFriendsHostInternal.h"

#import <os/log.h>

@implementation SZFriendsCheckInClient (Reservation)

// `adoptable`: a welcome may name another ID than the one claimed (this key already holds one on record); an
// answer after a collision must name exactly the ID just drawn. Anything else counts as "unavailable". The
// attestation is looked at only once the reservation itself is believed.
- (void)handleReservation:(id)result friendsID:(id)value attestation:(id)attestation adoptable:(BOOL)adoptable {
    NSString *friendsID = [result isEqual:@"reserved"] ? SZFriendsHostCanonicalID(value, self.idCodec) : nil;
    if (friendsID && !adoptable && ![friendsID isEqualToString:_pendingID]) friendsID = nil;
    if ([result isEqual:@"reserved"] && friendsID == nil) {
        os_log_error(OS_LOG_DEFAULT, "Friends: a host reserved an ID this helper cannot accept");
        result = @"unavailable";
    }
    if (friendsID) {
        SZFriendsHostCancelTimer(&_reserveTimer);
        _attempt = 0;
        self.friendsIDReserved = YES;
        if (_collisions > 0) {
            [self.delegate checkInDidRenameIDFrom:_originalID to:friendsID];
        } else {
            [self.delegate checkInDidReserveID:friendsID];
        }
        _originalID = friendsID;
        _pendingID = friendsID;
        _collisions = 0;
        [self takeAttestation:attestation forFriendsID:friendsID];
    } else if (([result isEqual:@"taken"] || [result isEqual:@"invalid"]) && !self.drawsIDs) {
        // A device that joined a profile never draws an ID: the person's ID is reserved from their first device.
        self.friendsIDReserved = NO;
        os_log_info(OS_LOG_DEFAULT, "Friends: the profile's ID is not reserved; its first device will draw one");
    } else if ([result isEqual:@"taken"] || [result isEqual:@"invalid"]) {
        self.friendsIDReserved = NO;
        _collisions += 1;
        if (_collisions > SZFriendsHostMaxReservesPerConnection || _draws >= SZFriendsHostMaxDrawsPerLaunch) {
            // The host closes the connection after 20 tries anyway; the next connection starts over, until 40
            // draws in one launch, after which the ID stays unreserved until the next launch.
            os_log_error(OS_LOG_DEFAULT, "Friends: no free Friends ID after %lu tries", (unsigned long)_draws);
            return;
        }
        _draws += 1;
        _pendingID = _idProvider(_collisions);
        [self send:@"reserve" fields:@{@"friends_id" : _pendingID}];
    } else if ([result isEqual:@"unavailable"]) {
        [self scheduleReserveRetry];
    }
}

// The main host is down behind a replica: the ID stays unreserved, and this connection asks again later (1 min,
// doubling to 15 min, with jitter) rather than waiting for the next launch.
- (void)scheduleReserveRetry {
    double base = MIN(900.0, 60.0 * (double)(1u << MIN(_unavailableRetries, 4u)));
    _unavailableRetries += 1;
    SZFriendsHostCancelTimer(&_reserveTimer);
    _reserveTimer = [self timerAfter:base * (0.5 + 0.5 * (arc4random() / 4294967296.0))
                             handler:^(SZFriendsCheckInClient *client) {
                                 client->_reserveTimer = nil;
                                 if (client->_phase != SZFriendsCheckInPhaseCheckedIn) return;
                                 [client send:@"reserve" fields:@{@"friends_id" : client->_pendingID}];
                             }];
}

@end
