// The Friends ID reservation state machine (SZFriendsIdentity.h, brief § Friends ID, ADR 0006).

#import "service/identity/SZFriendsIdentityInternal.h"

// ADR 0006: three collisions in a row mean three-word draws from then on.
static const NSUInteger SZFriendsStickyCollisions = 3;

@implementation SZFriendsIDStatus

- (instancetype)initWithFriendsID:(NSString *)friendsID
                            state:(SZFriendsIDState)state
                       previousID:(nullable NSString *)previousID
                 collisionsInARow:(NSUInteger)collisionsInARow {
    if ((self = [super init])) {
        _friendsID = [friendsID copy];
        _state = state;
        // The notice text names the old ID, so it exists exactly while there is a notice to show.
        _previousID = state == SZFriendsIDStateChanged ? [previousID copy] : nil;
        _collisionsInARow = collisionsInARow;
    }
    return self;
}

+ (instancetype)initialStatusWithCodec:(SZFriendsIDCodec *)codec
                        listNewIDWords:(NSInteger)listNewIDWords
                             generator:(SZFriendsRandomUniform)generator {
    NSString *friendsID = [codec randomIDWithWordCount:SZFriendsWordCountForNewID(listNewIDWords, 0)
                                             generator:generator];
    return [[self alloc] initWithFriendsID:friendsID state:SZFriendsIDStateUnreserved previousID:nil
                          collisionsInARow:0];
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self; // immutable
}

- (SZFriendsIDStatus *)withFriendsID:(NSString *)friendsID
                               state:(SZFriendsIDState)state
                          previousID:(nullable NSString *)previousID
                          collisions:(NSUInteger)collisions {
    return [[SZFriendsIDStatus alloc] initWithFriendsID:friendsID state:state previousID:previousID
                                       collisionsInARow:collisions];
}

// A reservation ends a run of collisions, unless the run already reached three: from then on stays from then on.
- (NSUInteger)collisionsAfterSuccess {
    return _collisionsInARow >= SZFriendsStickyCollisions ? _collisionsInARow : 0;
}

- (SZFriendsIDStatus *)statusAfterCollision {
    return [self withFriendsID:_friendsID state:_state previousID:_previousID collisions:_collisionsInARow + 1];
}

- (NSString *)replacementIDWithCodec:(SZFriendsIDCodec *)codec
                      listNewIDWords:(NSInteger)listNewIDWords
                           generator:(SZFriendsRandomUniform)generator {
    NSUInteger words = SZFriendsWordCountForNewID(listNewIDWords, _collisionsInARow);
    NSString *candidate;
    // Redrawing the refused ID would only collide again; with 4 million IDs this loop almost never repeats.
    do {
        candidate = [codec randomIDWithWordCount:words generator:generator];
    } while ([candidate isEqualToString:_friendsID]);
    return candidate;
}

- (SZFriendsIDStatus *)statusAfterReservationOf:(NSString *)reservedID {
    // A different ID here is the one the host already holds for this key: the same person reinstalling, whose
    // friends know that ID. Nothing was taken from them, so there is no "changed" notice to give.
    BOOL keepNotice = _state == SZFriendsIDStateChanged && [reservedID isEqualToString:_friendsID];
    return [self withFriendsID:reservedID
                         state:keepNotice ? SZFriendsIDStateChanged : SZFriendsIDStateReserved
                    previousID:keepNotice ? _previousID : nil
                    collisions:[self collisionsAfterSuccess]];
}

- (SZFriendsIDStatus *)statusAfterRenameFrom:(NSString *)oldID to:(NSString *)newID {
    // While an earlier notice is still unread, the ID the person last knew is that notice's old ID, not the
    // in-between one they never saw.
    NSString *known = (_state == SZFriendsIDStateChanged && _previousID != nil) ? _previousID : oldID;
    if ([newID isEqualToString:known]) {
        return [self withFriendsID:newID state:SZFriendsIDStateReserved previousID:nil
                        collisions:[self collisionsAfterSuccess]];
    }
    return [self withFriendsID:newID state:SZFriendsIDStateChanged previousID:known
                    collisions:[self collisionsAfterSuccess]];
}

- (SZFriendsIDStatus *)statusAfterNoticeDismissed {
    if (_state != SZFriendsIDStateChanged) return self;
    return [self withFriendsID:_friendsID state:SZFriendsIDStateReserved previousID:nil collisions:_collisionsInARow];
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[SZFriendsIDStatus class]]) return NO;
    SZFriendsIDStatus *other = object;
    return [_friendsID isEqualToString:other->_friendsID] && _state == other->_state &&
           (_previousID == other->_previousID || [_previousID isEqualToString:other->_previousID]) &&
           _collisionsInARow == other->_collisionsInARow;
}

- (NSUInteger)hash {
    return _friendsID.hash ^ (NSUInteger)_state ^ (_collisionsInARow << 8);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SZFriendsIDStatus %@ state %ld previous %@ collisions %lu>", _friendsID,
                                      (long)_state, _previousID ?: @"-", (unsigned long)_collisionsInARow];
}

@end
