#import "SPDFMacAISignInReturnWatch.h"
#import <AppKit/AppKit.h>

@implementation SPDFMacAISignInReturnWatch {
    __weak id<SPDFMacAIBrowserSignIn> _signIn;
    NSTimeInterval _delay;
    void (^_lostWayBack)(void);
    NSArray* _observers;
    NSUInteger _visit; // bumped on every arrival and departure, so a pending check knows it is stale
}

- (instancetype)initWithSignIn:(id<SPDFMacAIBrowserSignIn>)signIn
                         delay:(NSTimeInterval)delay
                   lostWayBack:(void (^)(void))lostWayBack {
    if (!(self = [super init])) return nil;
    _signIn = signIn; _delay = delay; _lostWayBack = [lostWayBack copy];
    __weak SPDFMacAISignInReturnWatch* weakSelf = self;
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    _observers = @[
        [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification* note) { (void)note; [weakSelf readerReturned]; }],
        [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification* note) { (void)note; [weakSelf readerLeft]; }],
    ];
    return self;
}

- (void)readerReturned {
    if (!_observers) return;
    NSUInteger visit = ++_visit;
    __weak SPDFMacAISignInReturnWatch* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf checkVisit:visit];
    });
}

- (void)readerLeft { ++_visit; }

- (void)checkVisit:(NSUInteger)visit {
    if (!_observers || visit != _visit) return;
    id<SPDFMacAIBrowserSignIn> signIn = _signIn;
    if (signIn && [signIn isAwaitingBrowser] && _lostWayBack) _lostWayBack();
}

- (void)stop {
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    _observers = nil; _lostWayBack = nil;
}

- (void)dealloc { [self stop]; }

@end
