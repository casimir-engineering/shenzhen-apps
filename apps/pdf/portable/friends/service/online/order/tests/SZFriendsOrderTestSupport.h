// Shared helpers for the online order suite: checks, a scripted clock and jitter, orders built on them.

#import <Foundation/Foundation.h>

#import "service/online/order/SZFriendsOnlineOrder.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFOrderFailures;

// Records a failure and carries on, so one run reports every broken expectation.
#define CHECK(condition, ...)                                                                                        \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            SZFOrderFailures++;                                                                                      \
            fprintf(stderr, "%s:%d: CHECK failed: %s %s\n", __FILE__, __LINE__, #condition,                          \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                       \
        }                                                                                                            \
    } while (0)

// The clock and the jitter every order in a test reads. random 0.5 means no jitter.
@interface SZFOrderClock : NSObject
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) double random;
@end

SZFriendsOnlineOrder *SZFOrderMake(SZFriendsOnlineRole role, SZFOrderClock *clock);
// Moves the clock to the order's next deadline and fires it.
SZFriendsOnlineOrderActions SZFOrderAdvance(SZFriendsOnlineOrder *order, SZFOrderClock *clock);
SZFriendsOnlineRoute SZFOrderRoute(SZFriendsOnlineTechnique technique);

void SZFriendsRunOrderPhaseTests(void);
void SZFriendsRunOrderRetryTests(void);
void SZFriendsRunTechniqueLogTests(void);

NS_ASSUME_NONNULL_END
