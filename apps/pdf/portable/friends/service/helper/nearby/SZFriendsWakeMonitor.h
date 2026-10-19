// Sleep and wake, as the helper needs them: make received bytes durable before the Mac sleeps, and look again
// for people as soon as it wakes (ADR 0004: adapters restart after wake). Internal to the helper.
//
// IOKit's system power notifications rather than AppKit's NSWorkspace ones: the helper is Foundation-only and
// background-only, and polling a clock for gaps would wake the CPU for nothing all day.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsWakeMonitor : NSObject
// Both run on `queue`. `willSleep` must finish its work before returning: the system waits for the answer that
// follows it, for 30 seconds at most.
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    willSleep:(void (^)(void))willSleep
                       didWake:(void (^)(void))didWake NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)start; // NO when the system refused the registration (logged); the helper works on without it
- (void)stop;
@end

NS_ASSUME_NONNULL_END
