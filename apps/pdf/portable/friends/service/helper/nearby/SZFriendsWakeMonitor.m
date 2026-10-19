// System sleep and wake notifications for the helper (SZFriendsWakeMonitor.h).

#import "service/helper/nearby/SZFriendsWakeMonitor.h"

#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

#import "service/helper/SZFriendsHelperInternal.h"

@interface SZFriendsWakeMonitor ()
- (void)handleMessage:(natural_t)messageType argument:(void *)argument;
@end

static void SZFriendsPowerCallback(void *refcon, io_service_t service, natural_t messageType, void *argument) {
    (void)service;
    [(__bridge SZFriendsWakeMonitor *)refcon handleMessage:messageType argument:argument];
}

@implementation SZFriendsWakeMonitor {
    dispatch_queue_t _queue;
    void (^_willSleep)(void);
    void (^_didWake)(void);
    io_connect_t _rootPort;
    IONotificationPortRef _port;
    io_object_t _notifier;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    willSleep:(void (^)(void))willSleep
                       didWake:(void (^)(void))didWake {
    if ((self = [super init])) {
        _queue = queue;
        _willSleep = [willSleep copy];
        _didWake = [didWake copy];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start {
    if (_port != NULL) return YES;
    _rootPort = IORegisterForSystemPower((__bridge void *)self, &_port, SZFriendsPowerCallback, &_notifier);
    if (_rootPort == MACH_PORT_NULL) {
        _port = NULL;
        SZFriendsHelperLog(@"sleep and wake notifications unavailable");
        return NO;
    }
    IONotificationPortSetDispatchQueue(_port, _queue);
    return YES;
}

- (void)stop {
    if (_port == NULL) return;
    IODeregisterForSystemPower(&_notifier);
    IOServiceClose(_rootPort);
    IONotificationPortDestroy(_port);
    _port = NULL;
    _rootPort = MACH_PORT_NULL;
}

- (void)handleMessage:(natural_t)messageType argument:(void *)argument {
    switch (messageType) {
    case kIOMessageCanSystemSleep:
        // Idle sleep asks first; Friends never holds the Mac awake.
        IOAllowPowerChange(_rootPort, (long)argument);
        break;
    case kIOMessageSystemWillSleep:
        // Every acknowledged byte on disk before the lid closes; then let the system go, or it waits 30 s for us.
        if (_willSleep) _willSleep();
        IOAllowPowerChange(_rootPort, (long)argument);
        break;
    case kIOMessageSystemHasPoweredOn:
        if (_didWake) _didWake();
        break;
    default:
        break;
    }
}

@end
