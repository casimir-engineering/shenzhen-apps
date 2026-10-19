#import "SPDFMacDelayedLinkActivation.h"

@implementation SPDFMacDelayedLinkActivation {
    NSTimeInterval _delay;
    NSUInteger _generation;
}

- (instancetype)init {
    return [self initWithDelay:NSEvent.doubleClickInterval];
}

- (instancetype)initWithDelay:(NSTimeInterval)delay {
    self = [super init];
    if (self) _delay = MAX(0.0, delay);
    return self;
}

- (void)schedulePageIndex:(NSInteger)pageIndex
                pagePoint:(NSPoint)pagePoint
                  handler:(SPDFMacLinkActivationHandler)handler {
    NSUInteger generation = ++_generation;
    __weak SPDFMacDelayedLinkActivation* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SPDFMacDelayedLinkActivation* self = weakSelf;
      if (!self || generation != self->_generation) return;
      ++self->_generation;
      if (handler) handler(pageIndex, pagePoint);
    });
}

- (void)cancel {
    ++_generation;
}

@end
