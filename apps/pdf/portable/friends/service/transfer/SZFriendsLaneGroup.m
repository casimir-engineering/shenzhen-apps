// A first session and its lanes (SZFriendsLaneGroup.h).

#import "service/transfer/SZFriendsLaneGroup.h"

const uint8_t SZFriendsLaneIndexMax = 15;
const NSUInteger SZFriendsLanesPerRoute = 4;
const NSUInteger SZFriendsLanesOpenedPerGroup = 8;

BOOL SZFriendsOneLaneOnly(SZFriendsRouteMethod route) {
    return route == SZFriendsRouteMethodRelay || route == SZFriendsRouteMethodBluetooth ||
           route == SZFriendsRouteMethodNone;
}

@implementation SZFriendsLaneEvent
+ (instancetype)up:(SZFriendsLaneID)lane index:(uint8_t)index route:(SZFriendsRouteMethod)route {
    SZFriendsLaneEvent *event = [[self alloc] init];
    event->_up = YES;
    event->_lane = lane;
    event->_index = index;
    event->_route = route;
    return event;
}
+ (instancetype)down:(SZFriendsLaneID)lane {
    SZFriendsLaneEvent *event = [[self alloc] init];
    event->_lane = lane;
    return event;
}
@end

typedef struct {
    BOOL used;
    SZFriendsLaneID lane;
    SZFriendsRouteMethod route;
    BOOL live;
    BOOL outbound;
} SZFriendsLaneSlot;

@implementation SZFriendsLaneGroup {
    BOOL _odd;
    uint8_t _tokens[15][16];
    SZFriendsLaneSlot _slots[16]; // by index
    NSMutableArray<SZFriendsLaneEvent *> *_events;
}

- (instancetype)initWithFirst:(SZFriendsLaneID)first
                 handshakeHash:(NSData *)handshakeHash
                     initiator:(BOOL)initiator
                         route:(SZFriendsRouteMethod)route {
    if ((self = [super init])) {
        _odd = initiator;
        for (uint8_t index = 1; index <= SZFriendsLaneIndexMax; index++) {
            NSData *token = SZFriendsLaneToken(handshakeHash, index);
            if (token.length == 16) memcpy(_tokens[index - 1], token.bytes, 16);
        }
        _slots[0] = (SZFriendsLaneSlot){YES, first, route, YES, NO};
        _events = [NSMutableArray arrayWithObject:[SZFriendsLaneEvent up:first index:0 route:route]];
    }
    return self;
}

- (SZFriendsLaneID)first {
    if (_slots[0].used) return _slots[0].lane;
    for (int i = 1; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used && _slots[i].live) return _slots[i].lane;
    }
    for (int i = 1; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used) return _slots[i].lane;
    }
    return 0;
}

- (int)slotOf:(SZFriendsLaneID)lane {
    for (int i = 0; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used && _slots[i].lane == lane) return i;
    }
    return -1;
}

- (BOOL)contains:(SZFriendsLaneID)lane {
    return [self slotOf:lane] >= 0;
}

- (BOOL)routeTaken:(SZFriendsRouteMethod)route {
    return SZFriendsOneLaneOnly(route) && [self hasRoute:route];
}

- (BOOL)hasRoute:(SZFriendsRouteMethod)route {
    for (int i = 0; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used && _slots[i].route == route) return YES;
    }
    return NO;
}

- (uint8_t)reserve:(SZFriendsLaneID)lane route:(SZFriendsRouteMethod)route token:(NSData **)token {
    NSUInteger opened = 0, onRoute = 0;
    for (int i = 0; i <= SZFriendsLaneIndexMax; i++) {
        if (!_slots[i].used || !_slots[i].outbound) continue;
        opened++;
        if (_slots[i].route == route) onRoute++;
    }
    if (opened >= SZFriendsLanesOpenedPerGroup || onRoute >= SZFriendsLanesPerRoute || [self routeTaken:route]) return 0;
    for (uint8_t index = 1; index <= SZFriendsLaneIndexMax; index++) {
        if ((index % 2 == 1) != _odd || _slots[index].used) continue;
        _slots[index] = (SZFriendsLaneSlot){YES, lane, route, NO, YES};
        if (token) *token = [NSData dataWithBytes:_tokens[index - 1] length:16];
        return index;
    }
    return 0;
}

- (SZFriendsLaneRefusal)admit:(SZFriendsLaneID)lane
                        token:(NSData *)token
                        route:(SZFriendsRouteMethod)route
                        index:(uint8_t *)indexOut {
    // Every index compared, in time that depends only on the lengths.
    uint8_t found = 0;
    for (uint8_t index = 1; index <= SZFriendsLaneIndexMax; index++) {
        uint8_t difference = token.length == 16 ? 0 : 1;
        const uint8_t *given = token.length == 16 ? token.bytes : _tokens[0];
        for (int i = 0; i < 16; i++) difference |= given[i] ^ _tokens[index - 1][i];
        uint8_t same = (uint8_t)((((uint16_t)difference) - 1) >> 8);
        found |= index & same;
    }
    if (found == 0) return SZFriendsLaneRefusedToken;
    if (_slots[found].used) return SZFriendsLaneRefusedInUse;
    if ([self routeTaken:route]) return SZFriendsLaneRefusedFull;
    _slots[found] = (SZFriendsLaneSlot){YES, lane, route, NO, NO};
    *indexOut = found;
    return SZFriendsLaneAdmitted;
}

- (SZFriendsRouteMethod)routeOf:(SZFriendsLaneID)lane {
    int slot = [self slotOf:lane];
    return slot >= 0 ? _slots[slot].route : SZFriendsRouteMethodNone;
}

- (uint8_t)indexOf:(SZFriendsLaneID)lane {
    int slot = [self slotOf:lane];
    return slot > 0 ? (uint8_t)slot : 0;
}

- (NSArray<NSNumber *> *)lanesOnly {
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 1; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used) [out addObject:@(_slots[i].lane)];
    }
    return out;
}

- (void)laneUp:(SZFriendsLaneID)lane {
    int slot = [self slotOf:lane];
    if (slot < 0 || _slots[slot].live) return;
    _slots[slot].live = YES;
    [_events addObject:[SZFriendsLaneEvent up:lane index:(uint8_t)slot route:_slots[slot].route]];
}

- (BOOL)laneDown:(SZFriendsLaneID)lane {
    int slot = [self slotOf:lane];
    if (slot < 0) return NO;
    if (_slots[slot].live) [_events addObject:[SZFriendsLaneEvent down:lane]];
    _slots[slot].used = NO;
    for (int i = 0; i <= SZFriendsLaneIndexMax; i++) {
        if (_slots[i].used && _slots[i].live) return NO;
    }
    return YES;
}

- (NSArray<SZFriendsLaneEvent *> *)takeEvents {
    NSArray *events = [_events copy];
    [_events removeAllObjects];
    return events;
}

@end
